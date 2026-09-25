// Command agent_zero is the Docker host agent the mobile app talks to.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"agent_zero/internal/alerts"
	"agent_zero/internal/audit"
	"agent_zero/internal/auth"
	"agent_zero/internal/compose"
	"agent_zero/internal/config"
	"agent_zero/internal/control"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/httpapi"
	"agent_zero/internal/jobs"
	"agent_zero/internal/registry"
	"agent_zero/internal/settings"
	"agent_zero/internal/store"
	"agent_zero/internal/tlsx"
	"agent_zero/internal/version"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "agent_zero:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	// Subcommands come before flags.
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd := args[0]
		rest := args[1:]
		switch cmd {
		case "serve":
			return serve(rest)
		case "pair-token":
			return pairToken(rest)
		case "version":
			fmt.Println(version.Version)
			return nil
		case "help":
			usage()
			return nil
		default:
			usage()
			return fmt.Errorf("unknown command %q", cmd)
		}
	}
	return serve(args)
}

func usage() {
	fmt.Fprint(os.Stderr, `agent_zero - Docker host agent

Usage:
  agent_zero [serve] [flags]   run the agent (default)
  agent_zero pair-token        ask the running agent for a pairing token
  agent_zero version           print the version

Flags (each has an AGENT_ZERO_* environment variable):
  --listen          listen address, default :8443
  --data-dir        data directory, default /var/lib/agent_zero
  --stacks-dir      compose stacks directory, default /opt/stacks
  --docker-host     docker host, e.g. unix:///var/run/docker.sock
  --docker-bin      docker CLI used for compose, default docker
  --tls-cert        PEM certificate; a self-signed one is generated when empty
  --tls-key         PEM private key
  --insecure-http   serve plain HTTP, local development only
  --log-level       debug|info|warn|error
`)
}

func newLogger(level string) *slog.Logger {
	var l slog.Level
	switch level {
	case "debug":
		l = slog.LevelDebug
	case "warn":
		l = slog.LevelWarn
	case "error":
		l = slog.LevelError
	default:
		l = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: l}))
}

func pairToken(args []string) error {
	cfg, err := config.Parse(args)
	if err != nil {
		return err
	}
	resp, err := control.RequestPairToken(filepath.Join(cfg.DataDir, control.SocketName))
	if err != nil {
		return fmt.Errorf("%w\n(the agent must be running, and this command must run as the same user)", err)
	}
	fmt.Printf("Pairing token: %s\n", resp.Token)
	fmt.Printf("Valid until:   %s\n", resp.ExpiresAt.Local().Format(time.RFC3339))
	fmt.Println("It can be used once.")
	return nil
}

func serve(args []string) error {
	cfg, err := config.Parse(args)
	if err != nil {
		return err
	}
	log := newLogger(cfg.LogLevel)
	slog.SetDefault(log)

	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return fmt.Errorf("data dir: %w", err)
	}

	st, err := store.Open(cfg.DBPath())
	if err != nil {
		return err
	}
	defer st.Close()

	sealer, err := registry.LoadOrCreateKey(cfg.SecretKeyPath())
	if err != nil {
		return err
	}

	authMgr := auth.NewManager(st, cfg.PairTokenTTL)
	auditLog := audit.NewBoltLogger(st)
	registries := registry.NewManager(st, sealer, auth.RandomID)

	settingsMgr, err := settings.NewManager(st, settings.Settings{
		RequireBiometricForRisky: true,
		StacksDir:                cfg.StacksDir,
	})
	if err != nil {
		return err
	}

	alertStore, err := alerts.NewStore(st)
	if err != nil {
		return err
	}

	docker, err := dockerx.New(cfg.DockerHost)
	if err != nil {
		return err
	}
	defer docker.Close()

	pingCtx, pingCancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := docker.Ping(pingCtx); err != nil {
		log.Warn("the Docker daemon is not reachable yet; Docker endpoints will answer 502 until it is",
			"error", err)
	} else {
		if info, err := docker.Info(context.Background()); err == nil {
			log.Info("connected to Docker", "version", info.DockerVersion, "host", info.Hostname, "swarm", info.SwarmRole)
		}
	}
	pingCancel()

	jobMgr := jobs.New(jobs.Options{})
	discoverer := &compose.Discoverer{StacksDir: settingsMgr.Get().StacksDir, Docker: docker}
	runner := &compose.Runner{Bin: cfg.DockerBin}

	// TLS material and the fingerprint the phone pins.
	fingerprint := ""
	var tlsMaterial tlsx.Material
	if cfg.InsecureHTTP {
		log.Warn("!!! --insecure-http is set: the API is served over plain HTTP !!!")
		log.Warn("!!! device keys travel in clear text; use this for local development only !!!")
	} else {
		certPath, keyPath := cfg.CertPath(), cfg.KeyPath()
		selfSigned := true
		if cfg.TLSCert != "" {
			certPath, keyPath, selfSigned = cfg.TLSCert, cfg.TLSKey, false
		}
		tlsMaterial, err = tlsx.Load(certPath, keyPath, selfSigned)
		if err != nil {
			return err
		}
		fingerprint = tlsMaterial.Fingerprint
		kind := "supplied"
		if tlsMaterial.SelfSigned {
			kind = "self-signed"
		}
		log.Info("TLS ready", "certificate", kind, "path", certPath)
		fmt.Printf("\nCertificate SHA-256 fingerprint (the app pins this):\n  %s\n\n", fingerprint)
	}

	api := httpapi.NewServer(httpapi.Deps{
		Log:             log,
		Docker:          docker,
		Auth:            authMgr,
		Audit:           auditLog,
		Jobs:            jobMgr,
		Alerts:          alertStore,
		Registries:      registries,
		Settings:        settingsMgr,
		Compose:         discoverer,
		ComposeRunner:   runner,
		Version:         version.Version,
		StartedAt:       time.Now(),
		CertFingerprint: fingerprint,
		StacksDir:       settingsMgr.Get().StacksDir,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// First-run pairing token.
	devices, err := authMgr.List()
	if err != nil {
		return err
	}
	if len(devices) == 0 {
		token, exp, err := authMgr.NewPairingToken()
		if err != nil {
			return err
		}
		fmt.Printf("No device is paired yet. One-time pairing token:\n  %s\nValid until %s\n\n",
			token, exp.Local().Format(time.RFC3339))
	} else {
		log.Info("devices paired", "count", len(devices))
	}

	closeControl, err := control.Serve(ctx, filepath.Join(cfg.DataDir, control.SocketName),
		authMgr.NewPairingToken, log)
	if err != nil {
		log.Warn("the control socket is unavailable; `agent_zero pair-token` will not work", "error", err)
	} else {
		defer closeControl()
	}

	// Alert evaluation.
	evaluator := alerts.NewEvaluator(alertStore, docker, alerts.LogNotifier{Log: log}, log, cfg.AlertsPeriod)
	go evaluator.Run(ctx)

	srv := &http.Server{
		Addr:    cfg.Listen,
		Handler: api.Handler(),
		// Streaming endpoints clear their own write deadline, so the server
		// wide write timeout stays off and slow reads are bounded instead.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		WriteTimeout:      0,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 * 1024,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelDebug),
		BaseContext:       func(net.Listener) context.Context { return context.Background() },
	}

	errCh := make(chan error, 1)
	go func() {
		if cfg.InsecureHTTP {
			log.Info("listening", "addr", cfg.Listen, "scheme", "http")
			errCh <- srv.ListenAndServe()
			return
		}
		srv.TLSConfig = tlsx.ServerConfig(tlsMaterial)
		log.Info("listening", "addr", cfg.Listen, "scheme", "https")
		errCh <- srv.ListenAndServeTLS("", "")
	}()

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Warn("http shutdown", "error", err)
	}
	jobMgr.Shutdown(shutdownCtx)
	return nil
}
