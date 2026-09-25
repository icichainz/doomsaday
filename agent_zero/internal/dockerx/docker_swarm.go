package dockerx

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/docker/docker/api/types/filters"
	"github.com/docker/docker/api/types/swarm"
)

// SwarmInfo describes the cluster from this node's point of view. When the
// node is not a manager the node list is empty but the call still succeeds,
// so the app can show "worker" or "not in a swarm".
func (d *Docker) SwarmInfo(ctx context.Context) (SwarmInfo, error) {
	info, err := d.Info(ctx)
	if err != nil {
		return SwarmInfo{}, err
	}
	out := SwarmInfo{
		Active:   info.SwarmRole != "inactive",
		NodeID:   info.SwarmNodeID,
		NodeRole: info.SwarmRole,
		Manager:  info.SwarmRole == "manager",
		Nodes:    []SwarmNode{},
	}
	if !out.Manager {
		return out, nil
	}
	sw, err := d.cli.SwarmInspect(ctx)
	if err == nil {
		out.ClusterID = sw.ID
	}
	nodes, err := d.cli.NodeList(ctx, swarm.NodeListOptions{})
	if err != nil {
		return SwarmInfo{}, wrap(err)
	}
	for _, n := range nodes {
		item := SwarmNode{
			ID:            n.ID,
			Hostname:      n.Description.Hostname,
			Role:          string(n.Spec.Role),
			Availability:  string(n.Spec.Availability),
			Status:        string(n.Status.State),
			Addr:          n.Status.Addr,
			EngineVersion: n.Description.Engine.EngineVersion,
			CreatedAt:     n.CreatedAt.UTC(),
		}
		if n.ManagerStatus != nil {
			item.Leader = n.ManagerStatus.Leader
		}
		out.Nodes = append(out.Nodes, item)
	}
	sort.Slice(out.Nodes, func(i, j int) bool { return out.Nodes[i].Hostname < out.Nodes[j].Hostname })
	return out, nil
}

func (d *Docker) requireManager(ctx context.Context) error {
	info, err := d.Info(ctx)
	if err != nil {
		return err
	}
	if info.SwarmRole != "manager" {
		return ErrNotManager
	}
	return nil
}

// ServiceList lists Swarm services.
func (d *Docker) ServiceList(ctx context.Context) ([]Service, error) {
	if err := d.requireManager(ctx); err != nil {
		return nil, err
	}
	svcs, err := d.cli.ServiceList(ctx, swarm.ServiceListOptions{Status: true})
	if err != nil {
		return nil, wrap(err)
	}
	out := make([]Service, 0, len(svcs))
	for _, s := range svcs {
		item := Service{
			ID:        s.ID,
			Name:      s.Spec.Name,
			Image:     s.Spec.TaskTemplate.ContainerSpec.Image,
			Mode:      "replicated",
			CreatedAt: s.CreatedAt.UTC(),
			UpdatedAt: s.UpdatedAt.UTC(),
		}
		if s.Spec.Mode.Global != nil {
			item.Mode = "global"
		}
		if s.Spec.Mode.Replicated != nil && s.Spec.Mode.Replicated.Replicas != nil {
			item.Replicas = *s.Spec.Mode.Replicated.Replicas
		}
		if s.ServiceStatus != nil {
			item.Running = s.ServiceStatus.RunningTasks
			item.Replicas = s.ServiceStatus.DesiredTasks
		}
		if s.UpdateStatus != nil {
			item.UpdateState = string(s.UpdateStatus.State)
			item.UpdateMessage = s.UpdateStatus.Message
		}
		for _, p := range s.Endpoint.Ports {
			item.Ports = append(item.Ports, Port{
				PrivatePort: int(p.TargetPort),
				PublicPort:  int(p.PublishedPort),
				Type:        string(p.Protocol),
			})
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// ServiceTasks lists the tasks of one service.
func (d *Docker) ServiceTasks(ctx context.Context, serviceID string) ([]Task, error) {
	if err := d.requireManager(ctx); err != nil {
		return nil, err
	}
	f := filters.NewArgs()
	f.Add("service", serviceID)
	tasks, err := d.cli.TaskList(ctx, swarm.TaskListOptions{Filters: f})
	if err != nil {
		return nil, wrap(err)
	}
	nodeNames := map[string]string{}
	if nodes, err := d.cli.NodeList(ctx, swarm.NodeListOptions{}); err == nil {
		for _, n := range nodes {
			nodeNames[n.ID] = n.Description.Hostname
		}
	}
	out := make([]Task, 0, len(tasks))
	for _, t := range tasks {
		out = append(out, Task{
			ID:           t.ID,
			ServiceID:    t.ServiceID,
			Slot:         t.Slot,
			NodeID:       t.NodeID,
			NodeName:     nodeNames[t.NodeID],
			State:        string(t.Status.State),
			DesiredState: string(t.DesiredState),
			Error:        t.Status.Err,
			CreatedAt:    t.CreatedAt.UTC(),
			UpdatedAt:    t.UpdatedAt.UTC(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Slot != out[j].Slot {
			return out[i].Slot < out[j].Slot
		}
		return out[i].CreatedAt.Before(out[j].CreatedAt)
	})
	return out, nil
}

func (d *Docker) inspectService(ctx context.Context, id string) (swarm.Service, error) {
	svc, _, err := d.cli.ServiceInspectWithRaw(ctx, id, swarm.ServiceInspectOptions{})
	if err != nil {
		return swarm.Service{}, wrap(err)
	}
	return svc, nil
}

// ServiceScale sets the replica count of a replicated service.
func (d *Docker) ServiceScale(ctx context.Context, serviceID string, replicas uint64) error {
	if err := d.requireManager(ctx); err != nil {
		return err
	}
	svc, err := d.inspectService(ctx, serviceID)
	if err != nil {
		return err
	}
	if svc.Spec.Mode.Replicated == nil {
		return fmt.Errorf("%w: service %s is not replicated", ErrConflict, svc.Spec.Name)
	}
	spec := svc.Spec
	spec.Mode.Replicated.Replicas = &replicas
	_, err = d.cli.ServiceUpdate(ctx, serviceID, svc.Version, spec, swarm.ServiceUpdateOptions{})
	return wrap(err)
}

// ServiceUpdate applies a rolling update, optionally changing the image.
func (d *Docker) ServiceUpdate(ctx context.Context, serviceID string, opts ServiceUpdateOptions) error {
	if err := d.requireManager(ctx); err != nil {
		return err
	}
	svc, err := d.inspectService(ctx, serviceID)
	if err != nil {
		return err
	}
	spec := svc.Spec
	if opts.Image != "" {
		spec.TaskTemplate.ContainerSpec.Image = opts.Image
	}
	if opts.Force {
		spec.TaskTemplate.ForceUpdate++
	}
	_, err = d.cli.ServiceUpdate(ctx, serviceID, svc.Version, spec, swarm.ServiceUpdateOptions{})
	return wrap(err)
}

// ServiceRollback reverts a service to its previous spec.
func (d *Docker) ServiceRollback(ctx context.Context, serviceID string) error {
	if err := d.requireManager(ctx); err != nil {
		return err
	}
	svc, err := d.inspectService(ctx, serviceID)
	if err != nil {
		return err
	}
	if svc.PreviousSpec == nil {
		return fmt.Errorf("%w: service %s has no previous spec", ErrConflict, svc.Spec.Name)
	}
	_, err = d.cli.ServiceUpdate(ctx, serviceID, svc.Version, *svc.PreviousSpec, swarm.ServiceUpdateOptions{Rollback: "previous"})
	if err != nil && strings.Contains(err.Error(), "does not have a previous spec") {
		return fmt.Errorf("%w: %s", ErrConflict, err)
	}
	return wrap(err)
}
