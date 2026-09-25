package httpapi

import (
	"context"
	"net/http"
	"strings"
	"time"

	"agent_zero/internal/dockerx"
	"agent_zero/internal/jobs"
	"agent_zero/internal/registry"
)

type imageDTO struct {
	ID        string    `json:"id"`
	Tags      []string  `json:"tags"`
	Digests   []string  `json:"digests,omitempty"`
	Size      int64     `json:"size"`
	CreatedAt time.Time `json:"created_at"`
	Dangling  bool      `json:"dangling"`
	InUseBy   []string  `json:"in_use_by"`
}

type imagesSummary struct {
	Count            int   `json:"count"`
	TotalBytes       int64 `json:"total_bytes"`
	ReclaimableBytes int64 `json:"reclaimable_bytes"`
}

func (s *Server) handleImageList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	images, err := s.Docker.ImageList(r.Context())
	if err != nil {
		s.fail(w, "image", err)
		return
	}
	containers, err := s.Docker.ContainerList(r.Context(), dockerx.ContainerListOptions{})
	if err != nil {
		s.fail(w, "image", err)
		return
	}

	usedByID := map[string][]string{}
	usedByTag := map[string][]string{}
	for _, c := range containers {
		usedByID[c.ImageID] = append(usedByID[c.ImageID], c.Name)
		usedByTag[c.Image] = append(usedByTag[c.Image], c.Name)
	}

	search := r.URL.Query().Get("q")
	if len(search) > maxQueryLen {
		validationError(w, "q", "q is too long")
		return
	}

	du, duErr := s.Docker.DiskUsage(r.Context())
	summary := imagesSummary{}
	out := make([]imageDTO, 0, len(images))
	for _, img := range images {
		users := append([]string{}, usedByID[img.ID]...)
		for _, tag := range img.Tags {
			users = append(users, usedByTag[tag]...)
		}
		users = dedupe(users)

		if search != "" {
			match := strings.HasPrefix(img.ID, search)
			for _, t := range img.Tags {
				if containsFold(t, search) {
					match = true
				}
			}
			if !match {
				continue
			}
		}
		summary.TotalBytes += img.Size
		if len(users) == 0 {
			summary.ReclaimableBytes += img.Size - img.SharedSize
		}
		out = append(out, imageDTO{
			ID:        img.ID,
			Tags:      img.Tags,
			Digests:   img.Digests,
			Size:      img.Size,
			CreatedAt: img.CreatedAt,
			Dangling:  img.Dangling,
			InUseBy:   users,
		})
	}
	summary.Count = len(out)
	if duErr == nil {
		summary.TotalBytes = du.ImagesSize
		summary.ReclaimableBytes = du.ImagesReclaim
	}

	items, next := paginate(out, page)
	writeJSON(w, http.StatusOK, map[string]any{
		"items":       items,
		"next_cursor": next,
		"total":       len(out),
		"summary":     summary,
	})
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		out = append(out, s)
	}
	return out
}

type imagePullRequest struct {
	Ref string `json:"ref"`
}

func (s *Server) handleImagePull(w http.ResponseWriter, r *http.Request) {
	var body imagePullRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	ref := strings.TrimSpace(body.Ref)
	if ref == "" {
		validationError(w, "ref", "ref is required")
		return
	}
	if !validImageRef(ref) {
		validationError(w, "ref", "ref is not a valid image reference")
		return
	}

	// Resolve the credential now, so the secret never crosses the API layer
	// as anything but an opaque value handed to the Docker client.
	var auth *dockerx.RegistryAuth
	if cred, ok := s.Registries.CredentialForRef(ref); ok {
		auth = &dockerx.RegistryAuth{Host: cred.Host, Username: cred.Username, Secret: cred.Secret}
	}
	setAuditDetail(r, "ref", ref)
	setAuditDetail(r, "registry", registry.RegistryHostOf(ref))
	setAuditDetail(r, "with_credentials", auth != nil)

	s.startJob(w, r, "image_pull", ref, func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 60*time.Minute)
		defer cancel()

		h.Logf("pulling %s", ref)
		layers := map[string]int64{}
		var lastEmit time.Time

		err := s.Docker.ImagePull(ctx, ref, auth, func(p dockerx.PullProgress) {
			if p.ID != "" && p.Total > 0 {
				layers[p.ID] = p.Total
			}
			// Throttle: layer progress arrives many times a second.
			if time.Since(lastEmit) < 250*time.Millisecond && p.Status != "Download complete" {
				return
			}
			lastEmit = time.Now()
			pct := -1.0
			if p.Total > 0 {
				pct = float64(p.Current) / float64(p.Total) * 100
			}
			if p.ID != "" {
				h.Progressf(pct, "%s: %s", p.ID, p.Status)
			} else {
				h.Progressf(pct, "%s", p.Status)
			}
		})
		if err != nil {
			h.Fail("image_pull_failed", err.Error(), map[string]any{"ref": ref})
			return nil
		}
		h.Succeed(map[string]any{"ref": ref, "layers": len(layers)})
		return nil
	})
}

func (s *Server) handleImageRemove(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the image id is not valid")
		return
	}
	force, err := queryBool(r, "force")
	if err != nil {
		validationError(w, "force", err.Error())
		return
	}
	setAuditTarget(r, id)
	setAuditDetail(r, "force", force)

	if err := s.Docker.ImageRemove(r.Context(), id, force); err != nil {
		s.fail(w, "image", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type imagePruneRequest struct {
	DanglingOnly *bool `json:"dangling_only"`
}

func (s *Server) handleImagePrune(w http.ResponseWriter, r *http.Request) {
	body := imagePruneRequest{}
	if r.ContentLength > 0 {
		if err := decodeJSON(w, r, &body); err != nil {
			return
		}
	}
	dangling := true
	if body.DanglingOnly != nil {
		dangling = *body.DanglingOnly
	}
	setAuditDetail(r, "dangling_only", dangling)

	s.startJob(w, r, "image_prune", "images", func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 30*time.Minute)
		defer cancel()
		h.Logf("pruning images (dangling_only=%v)", dangling)
		res, err := s.Docker.ImagePrune(ctx, dangling)
		if err != nil {
			h.Fail("image_prune_failed", err.Error(), nil)
			return nil
		}
		h.Succeed(map[string]any{"deleted": res.Deleted, "space_reclaimed": res.SpaceReclaimed})
		return nil
	})
}

type volumeDTO struct {
	Name      string            `json:"name"`
	Driver    string            `json:"driver"`
	Size      int64             `json:"size"`
	CreatedAt time.Time         `json:"created_at"`
	MountedBy []string          `json:"mounted_by"`
	LastUsed  *time.Time        `json:"last_used,omitempty"`
	Labels    map[string]string `json:"labels,omitempty"`
	Scope     string            `json:"scope,omitempty"`
}

// volumesSummary is the header line above the volumes list: "9 volumes ·
// 46 GB · 2 not mounted". It is computed over the whole host, after any
// filter and before paging, the way the images summary is.
type volumesSummary struct {
	Count      int   `json:"count"`
	TotalBytes int64 `json:"total_bytes"`
	Unmounted  int   `json:"unmounted"`
}

func (s *Server) handleVolumeList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	search := r.URL.Query().Get("q")
	if len(search) > maxQueryLen {
		validationError(w, "q", "q is too long")
		return
	}
	volumes, err := s.Docker.VolumeList(r.Context())
	if err != nil {
		s.fail(w, "volume", err)
		return
	}
	containers, err := s.Docker.ContainerList(r.Context(), dockerx.ContainerListOptions{})
	if err != nil {
		s.fail(w, "volume", err)
		return
	}

	mounted := map[string][]string{}
	lastUsed := map[string]time.Time{}
	for _, c := range containers {
		det, err := s.Docker.ContainerInspect(r.Context(), c.ID)
		if err != nil {
			continue
		}
		for _, m := range det.Mounts {
			if m.Type != "volume" || m.Name == "" {
				continue
			}
			mounted[m.Name] = append(mounted[m.Name], c.Name)
			at := c.StartedAt
			if at.IsZero() {
				at = c.CreatedAt
			}
			if at.After(lastUsed[m.Name]) {
				lastUsed[m.Name] = at
			}
		}
	}

	summary := volumesSummary{}
	out := make([]volumeDTO, 0, len(volumes))
	for _, v := range volumes {
		if search != "" && !containsFold(v.Name, search) {
			continue
		}
		d := volumeDTO{
			Name:      v.Name,
			Driver:    v.Driver,
			Size:      v.Size,
			CreatedAt: v.CreatedAt,
			MountedBy: dedupe(mounted[v.Name]),
			Labels:    v.Labels,
			Scope:     v.Scope,
		}
		if t, ok := lastUsed[v.Name]; ok && !t.IsZero() {
			used := t
			d.LastUsed = &used
		}
		// Only the local driver reports a size; the others report 0 and so
		// add nothing to the total.
		summary.TotalBytes += d.Size
		if len(d.MountedBy) == 0 {
			summary.Unmounted++
		}
		out = append(out, d)
	}
	summary.Count = len(out)

	items, next := paginate(out, page)
	writeJSON(w, http.StatusOK, listResponse{
		Items: items, NextCursor: next, Total: len(out), Summary: summary,
	})
}

type volumeCreateRequest struct {
	Name   string            `json:"name"`
	Driver string            `json:"driver"`
	Labels map[string]string `json:"labels"`
}

func (s *Server) handleVolumeCreate(w http.ResponseWriter, r *http.Request) {
	var body volumeCreateRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if !resourceNameRe.MatchString(body.Name) {
		validationError(w, "name", "name must be 1 to 63 characters of letters, digits, dot, dash or underscore")
		return
	}
	if body.Driver != "" && !driverRe.MatchString(body.Driver) {
		validationError(w, "driver", "driver is not a valid driver name")
		return
	}
	if err := validateLabels(body.Labels); err != nil {
		validationError(w, "labels", err.Error())
		return
	}
	setAuditTarget(r, body.Name)

	vol, err := s.Docker.VolumeCreate(r.Context(), dockerx.VolumeCreateOptions{
		Name: body.Name, Driver: body.Driver, Labels: body.Labels,
	})
	if err != nil {
		s.fail(w, "volume", err)
		return
	}
	writeJSON(w, http.StatusCreated, vol)
}

func validateLabels(labels map[string]string) error {
	if len(labels) > 64 {
		return errTooManyLabels
	}
	for k, v := range labels {
		if k == "" || len(k) > 128 || len(v) > 1024 {
			return errBadLabel
		}
		if strings.HasPrefix(k, "com.docker.") {
			return errReservedLabel
		}
	}
	return nil
}

func (s *Server) handleVolumeRemove(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !resourceNameRe.MatchString(name) && !validID(name) {
		validationError(w, "name", "the volume name is not valid")
		return
	}
	force, err := queryBool(r, "force")
	if err != nil {
		validationError(w, "force", err.Error())
		return
	}
	setAuditTarget(r, name)

	if err := s.Docker.VolumeRemove(r.Context(), name, force); err != nil {
		s.fail(w, "volume", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleVolumePrune(w http.ResponseWriter, r *http.Request) {
	s.startJob(w, r, "volume_prune", "volumes", func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 30*time.Minute)
		defer cancel()
		h.Logf("pruning unused volumes")
		res, err := s.Docker.VolumePrune(ctx)
		if err != nil {
			h.Fail("volume_prune_failed", err.Error(), nil)
			return nil
		}
		h.Succeed(map[string]any{"deleted": res.Deleted, "space_reclaimed": res.SpaceReclaimed})
		return nil
	})
}

// networksSummary is the header line above the networks list: "7 networks ·
// 2 unused". Default networks are counted like any other.
type networksSummary struct {
	Count  int `json:"count"`
	Unused int `json:"unused"`
}

func (s *Server) handleNetworkList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	search := r.URL.Query().Get("q")
	if len(search) > maxQueryLen {
		validationError(w, "q", "q is too long")
		return
	}
	all, err := s.Docker.NetworkList(r.Context())
	if err != nil {
		s.fail(w, "network", err)
		return
	}

	summary := networksSummary{}
	nets := make([]dockerx.Network, 0, len(all))
	for _, n := range all {
		if search != "" && !containsFold(n.Name, search) && !strings.HasPrefix(n.ID, search) {
			continue
		}
		if n.Containers == 0 {
			summary.Unused++
		}
		nets = append(nets, n)
	}
	summary.Count = len(nets)

	items, next := paginate(nets, page)
	writeJSON(w, http.StatusOK, listResponse{
		Items: items, NextCursor: next, Total: len(nets), Summary: summary,
	})
}

type networkCreateRequest struct {
	Name       string `json:"name"`
	Driver     string `json:"driver"`
	Subnet     string `json:"subnet"`
	Attachable bool   `json:"attachable"`
}

func (s *Server) handleNetworkCreate(w http.ResponseWriter, r *http.Request) {
	var body networkCreateRequest
	if err := decodeJSON(w, r, &body); err != nil {
		return
	}
	if !resourceNameRe.MatchString(body.Name) {
		validationError(w, "name", "name must be 1 to 63 characters of letters, digits, dot, dash or underscore")
		return
	}
	if body.Driver != "" && !driverRe.MatchString(body.Driver) {
		validationError(w, "driver", "driver is not a valid driver name")
		return
	}
	if body.Subnet != "" && !validSubnet(body.Subnet) {
		validationError(w, "subnet", "subnet must be a CIDR such as 10.10.0.0/24")
		return
	}
	setAuditTarget(r, body.Name)

	net, err := s.Docker.NetworkCreate(r.Context(), dockerx.NetworkCreateOptions{
		Name: body.Name, Driver: body.Driver, Subnet: body.Subnet, Attachable: body.Attachable,
	})
	if err != nil {
		s.fail(w, "network", err)
		return
	}
	writeJSON(w, http.StatusCreated, net)
}

func (s *Server) handleNetworkRemove(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the network id is not valid")
		return
	}
	setAuditTarget(r, id)

	nets, err := s.Docker.NetworkList(r.Context())
	if err != nil {
		s.fail(w, "network", err)
		return
	}
	for _, n := range nets {
		if n.ID != id && n.Name != id {
			continue
		}
		if n.IsDefault {
			writeError(w, http.StatusConflict, codeConflict,
				"a default network cannot be removed", map[string]any{"network": n.Name})
			return
		}
		if n.Containers > 0 {
			writeError(w, http.StatusConflict, codeConflict,
				"containers are still attached to this network",
				map[string]any{"network": n.Name, "attached_containers": n.Containers})
			return
		}
	}
	if err := s.Docker.NetworkRemove(r.Context(), id); err != nil {
		s.fail(w, "network", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleNetworkPrune(w http.ResponseWriter, r *http.Request) {
	s.startJob(w, r, "network_prune", "networks", func(h *jobs.Handle) error {
		ctx, cancel := context.WithTimeout(h.Ctx, 10*time.Minute)
		defer cancel()
		h.Logf("pruning unused networks")
		res, err := s.Docker.NetworkPrune(ctx)
		if err != nil {
			h.Fail("network_prune_failed", err.Error(), nil)
			return nil
		}
		h.Succeed(map[string]any{"deleted": res.Deleted})
		return nil
	})
}
