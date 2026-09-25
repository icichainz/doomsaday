package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"agent_zero/internal/audit"
	"agent_zero/internal/dockerx"
	"agent_zero/internal/store"
)

const testSecret = "dckr_pat_super_secret_value_0123456789"

func (e *env) createRegistry(t *testing.T, host, user, secret string) string {
	t.Helper()
	rec := e.do("POST", "/v1/registries", withKey(e.adminKey), withJSON(map[string]any{
		"host": host, "username": user, "secret": secret,
	}))
	if rec.Code != http.StatusCreated {
		t.Fatalf("create registry = %d (%s)", rec.Code, rec.Body.String())
	}
	body := decode[map[string]any](t, rec)
	if strings.Contains(rec.Body.String(), secret) {
		t.Fatalf("the create response echoed the secret: %s", rec.Body.String())
	}
	return body["id"].(string)
}

func TestRegistrySecretNeverLeaves(t *testing.T) {
	e := newEnv(t)
	id := e.createRegistry(t, "registry.example.test", "robot", testSecret)

	t.Run("not in the list", func(t *testing.T) {
		rec := e.do("GET", "/v1/registries", withKey(e.viewerKey))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d", rec.Code)
		}
		if strings.Contains(rec.Body.String(), testSecret) {
			t.Fatalf("the list leaked the secret: %s", rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "sealed_secret") {
			t.Fatalf("the list leaked the ciphertext field: %s", rec.Body.String())
		}
	})

	t.Run("not in the test response", func(t *testing.T) {
		rec := e.do("POST", "/v1/registries/"+id+"/test", withKey(e.adminKey))
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), testSecret) {
			t.Fatalf("the test response leaked the secret: %s", rec.Body.String())
		}
	})

	t.Run("reaches only the docker client", func(t *testing.T) {
		got := ""
		for _, c := range e.fake.Calls() {
			if c.Method == "RegistryLogin" {
				got = c.Args[0].(dockerx.RegistryAuth).Secret
			}
		}
		if got != testSecret {
			t.Fatalf("the docker client received %q", got)
		}
	})

	t.Run("stored encrypted", func(t *testing.T) {
		found := false
		err := e.store.ForEach(store.BucketRegistries, func(_ string, raw []byte) error {
			found = true
			if strings.Contains(string(raw), testSecret) {
				t.Fatalf("the secret is stored in the clear: %s", raw)
			}
			var rec map[string]any
			if err := json.Unmarshal(raw, &rec); err != nil {
				return err
			}
			if rec["sealed_secret"] == nil || rec["sealed_secret"] == "" {
				t.Fatal("no sealed secret was stored")
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		if !found {
			t.Fatal("nothing was stored")
		}
	})

	t.Run("not in the audit log", func(t *testing.T) {
		records, _, err := e.audit.List(audit.Filter{Limit: 200})
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(records)
		if strings.Contains(string(raw), testSecret) {
			t.Fatalf("the audit log holds the secret: %s", raw)
		}
	})
}

func TestRegistryValidation(t *testing.T) {
	e := newEnv(t)
	for _, body := range []map[string]any{
		{"host": "", "username": "u", "secret": "s"},
		{"host": "has space", "username": "u", "secret": "s"},
		{"host": "ok.test", "username": "", "secret": "s"},
		{"host": "ok.test", "username": "u", "secret": ""},
		{"host": "ok.test/path?x=1", "username": "u", "secret": "s"},
	} {
		rec := e.do("POST", "/v1/registries", withKey(e.adminKey), withJSON(body))
		if rec.Code != http.StatusUnprocessableEntity {
			t.Fatalf("%v accepted with %d", body, rec.Code)
		}
	}
}

func TestRegistryUpdateAndDelete(t *testing.T) {
	e := newEnv(t)
	id := e.createRegistry(t, "registry.example.test", "robot", testSecret)

	rec := e.do("PATCH", "/v1/registries/"+id, withKey(e.adminKey),
		withJSON(map[string]any{"secret": "rotated-secret"}))
	if rec.Code != http.StatusOK {
		t.Fatalf("patch = %d (%s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "rotated-secret") {
		t.Fatal("the patch response echoed the new secret")
	}

	rec = e.do("DELETE", "/v1/registries/"+id, withKey(e.adminKey))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d", rec.Code)
	}
	rec = e.do("DELETE", "/v1/registries/"+id, withKey(e.adminKey))
	assertErrorEnvelope(t, rec, http.StatusNotFound)
}

func TestImagePullUsesTheStoredCredential(t *testing.T) {
	e := newEnv(t)
	e.createRegistry(t, "registry.example.test", "robot", testSecret)

	rec := e.do("POST", "/v1/images/pull", withKey(e.operatorKey),
		withJSON(map[string]any{"ref": "registry.example.test/team/app:1.2.3"}))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	jobID := decode[map[string]any](t, rec)["job_id"].(string)
	waitForJob(t, e, jobID)

	for _, c := range e.fake.Calls() {
		if c.Method == "ImagePull" {
			if c.Args[1] != true {
				t.Fatal("the pull did not carry the stored credential")
			}
			return
		}
	}
	t.Fatal("ImagePull was not called")
}

func TestImagePullWithoutACredential(t *testing.T) {
	e := newEnv(t)
	rec := e.do("POST", "/v1/images/pull", withKey(e.operatorKey),
		withJSON(map[string]any{"ref": "alpine:3.20"}))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d", rec.Code)
	}
	jobID := decode[map[string]any](t, rec)["job_id"].(string)
	waitForJob(t, e, jobID)
	for _, c := range e.fake.Calls() {
		if c.Method == "ImagePull" && c.Args[1] != false {
			t.Fatal("a credential was attached that does not exist")
		}
	}
}
