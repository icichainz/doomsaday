package dockerx

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"time"

	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/volume"
)

// ImageList lists local images.
func (d *Docker) ImageList(ctx context.Context) ([]Image, error) {
	sums, err := d.cli.ImageList(ctx, image.ListOptions{All: false})
	if err != nil {
		return nil, wrap(err)
	}
	out := make([]Image, 0, len(sums))
	for _, s := range sums {
		img := Image{
			ID:         s.ID,
			Tags:       s.RepoTags,
			Digests:    s.RepoDigests,
			Size:       s.Size,
			SharedSize: s.SharedSize,
			CreatedAt:  time.Unix(s.Created, 0).UTC(),
			Containers: s.Containers,
		}
		if len(img.Tags) == 0 || (len(img.Tags) == 1 && img.Tags[0] == "<none>:<none>") {
			img.Dangling = true
			img.Tags = []string{}
		}
		out = append(out, img)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

// ImagePull pulls an image, reporting layer progress.
func (d *Docker) ImagePull(ctx context.Context, ref string, auth *RegistryAuth, onProgress func(PullProgress)) error {
	rc, err := d.cli.ImagePull(ctx, ref, image.PullOptions{RegistryAuth: encodeAuth(auth)})
	if err != nil {
		return wrap(err)
	}
	defer rc.Close()

	dec := json.NewDecoder(rc)
	for {
		var msg struct {
			ID             string `json:"id"`
			Status         string `json:"status"`
			ProgressDetail struct {
				Current int64 `json:"current"`
				Total   int64 `json:"total"`
			} `json:"progressDetail"`
			Error string `json:"error"`
		}
		if err := dec.Decode(&msg); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return wrap(err)
		}
		if msg.Error != "" {
			return errors.New(msg.Error)
		}
		if onProgress != nil {
			onProgress(PullProgress{
				ID:      msg.ID,
				Status:  msg.Status,
				Current: msg.ProgressDetail.Current,
				Total:   msg.ProgressDetail.Total,
			})
		}
	}
}

// ImageRemove deletes an image.
func (d *Docker) ImageRemove(ctx context.Context, id string, force bool) error {
	_, err := d.cli.ImageRemove(ctx, id, image.RemoveOptions{Force: force, PruneChildren: true})
	return wrap(err)
}

// ImagePrune removes unused images.
func (d *Docker) ImagePrune(ctx context.Context, danglingOnly bool) (PruneResult, error) {
	f := filters.NewArgs()
	if danglingOnly {
		f.Add("dangling", "true")
	} else {
		f.Add("dangling", "false")
	}
	rep, err := d.cli.ImagesPrune(ctx, f)
	if err != nil {
		return PruneResult{}, wrap(err)
	}
	out := PruneResult{SpaceReclaimed: int64(rep.SpaceReclaimed), Deleted: []string{}}
	for _, it := range rep.ImagesDeleted {
		if it.Deleted != "" {
			out.Deleted = append(out.Deleted, it.Deleted)
		} else if it.Untagged != "" {
			out.Deleted = append(out.Deleted, it.Untagged)
		}
	}
	return out, nil
}

// VolumeList lists volumes with their size when the driver reports one.
func (d *Docker) VolumeList(ctx context.Context) ([]Volume, error) {
	resp, err := d.cli.VolumeList(ctx, volume.ListOptions{})
	if err != nil {
		return nil, wrap(err)
	}
	sizes := map[string]int64{}
	if du, err := d.cli.DiskUsage(ctx, dockerDiskUsageOptions()); err == nil {
		for _, v := range du.Volumes {
			if v != nil && v.UsageData != nil {
				sizes[v.Name] = v.UsageData.Size
			}
		}
	}

	out := make([]Volume, 0, len(resp.Volumes))
	for _, v := range resp.Volumes {
		if v == nil {
			continue
		}
		vol := Volume{
			Name:       v.Name,
			Driver:     v.Driver,
			Mountpoint: v.Mountpoint,
			Scope:      v.Scope,
			Labels:     v.Labels,
			Size:       sizes[v.Name],
		}
		if t, err := time.Parse(time.RFC3339Nano, v.CreatedAt); err == nil {
			vol.CreatedAt = t.UTC()
		}
		out = append(out, vol)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// VolumeCreate creates a volume.
func (d *Docker) VolumeCreate(ctx context.Context, opts VolumeCreateOptions) (Volume, error) {
	v, err := d.cli.VolumeCreate(ctx, volume.CreateOptions{
		Name:   opts.Name,
		Driver: opts.Driver,
		Labels: opts.Labels,
	})
	if err != nil {
		return Volume{}, wrap(err)
	}
	out := Volume{Name: v.Name, Driver: v.Driver, Mountpoint: v.Mountpoint, Scope: v.Scope, Labels: v.Labels}
	if t, err := time.Parse(time.RFC3339Nano, v.CreatedAt); err == nil {
		out.CreatedAt = t.UTC()
	}
	return out, nil
}

// VolumeRemove deletes a volume.
func (d *Docker) VolumeRemove(ctx context.Context, name string, force bool) error {
	return wrap(d.cli.VolumeRemove(ctx, name, force))
}

// VolumePrune removes unused volumes.
func (d *Docker) VolumePrune(ctx context.Context) (PruneResult, error) {
	rep, err := d.cli.VolumesPrune(ctx, filters.NewArgs())
	if err != nil {
		return PruneResult{}, wrap(err)
	}
	out := PruneResult{SpaceReclaimed: int64(rep.SpaceReclaimed), Deleted: []string{}}
	out.Deleted = append(out.Deleted, rep.VolumesDeleted...)
	return out, nil
}

// NetworkList lists networks with their attached container count.
func (d *Docker) NetworkList(ctx context.Context) ([]Network, error) {
	nets, err := d.cli.NetworkList(ctx, network.ListOptions{})
	if err != nil {
		return nil, wrap(err)
	}
	out := make([]Network, 0, len(nets))
	for _, n := range nets {
		item := Network{
			ID:         n.ID,
			Name:       n.Name,
			Driver:     n.Driver,
			Scope:      n.Scope,
			Internal:   n.Internal,
			Attachable: n.Attachable,
			Ingress:    n.Ingress,
			IsDefault:  isDefaultNetwork(n.Name),
			Subnets:    []string{},
		}
		for _, cfg := range n.IPAM.Config {
			if cfg.Subnet != "" {
				item.Subnets = append(item.Subnets, cfg.Subnet)
			}
		}
		// Containers is only filled by inspect; ask for it per network.
		if ins, err := d.cli.NetworkInspect(ctx, n.ID, network.InspectOptions{}); err == nil {
			item.Containers = len(ins.Containers)
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func isDefaultNetwork(name string) bool {
	switch name {
	case "bridge", "host", "none", "ingress", "docker_gwbridge":
		return true
	}
	return false
}

// NetworkCreate creates a user network.
func (d *Docker) NetworkCreate(ctx context.Context, opts NetworkCreateOptions) (Network, error) {
	cfg := network.CreateOptions{
		Driver:     opts.Driver,
		Attachable: opts.Attachable,
	}
	if opts.Subnet != "" {
		cfg.IPAM = &network.IPAM{Config: []network.IPAMConfig{{Subnet: opts.Subnet}}}
	}
	resp, err := d.cli.NetworkCreate(ctx, opts.Name, cfg)
	if err != nil {
		return Network{}, wrap(err)
	}
	ins, err := d.cli.NetworkInspect(ctx, resp.ID, network.InspectOptions{})
	if err != nil {
		return Network{ID: resp.ID, Name: opts.Name, Driver: opts.Driver, Subnets: []string{}}, nil
	}
	out := Network{
		ID:         ins.ID,
		Name:       ins.Name,
		Driver:     ins.Driver,
		Scope:      ins.Scope,
		Internal:   ins.Internal,
		Attachable: ins.Attachable,
		IsDefault:  isDefaultNetwork(ins.Name),
		Subnets:    []string{},
	}
	for _, c := range ins.IPAM.Config {
		if c.Subnet != "" {
			out.Subnets = append(out.Subnets, c.Subnet)
		}
	}
	return out, nil
}

// NetworkRemove deletes a network.
func (d *Docker) NetworkRemove(ctx context.Context, id string) error {
	return wrap(d.cli.NetworkRemove(ctx, id))
}

// NetworkPrune removes unused networks.
func (d *Docker) NetworkPrune(ctx context.Context) (PruneResult, error) {
	rep, err := d.cli.NetworksPrune(ctx, filters.NewArgs())
	if err != nil {
		return PruneResult{}, wrap(err)
	}
	return PruneResult{Deleted: append([]string{}, rep.NetworksDeleted...)}, nil
}
