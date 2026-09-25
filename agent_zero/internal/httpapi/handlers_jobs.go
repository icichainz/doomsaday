package httpapi

import (
	"net/http"
	"time"

	"agent_zero/internal/jobs"
	"agent_zero/internal/sse"
)

// startJob queues a job and answers 202 with its id, as the contract asks.
func (s *Server) startJob(w http.ResponseWriter, r *http.Request, typ, target string, fn func(*jobs.Handle) error) {
	dev, _ := deviceFrom(r)
	job, err := s.Jobs.Run(typ, target, dev.ID, fn)
	if err != nil {
		s.fail(w, "job", err)
		return
	}
	setAuditTarget(r, target)
	setAuditDetail(r, "job_id", job.ID)
	writeJSON(w, http.StatusAccepted, map[string]any{"job_id": job.ID, "job": job})
}

func (s *Server) handleJobList(w http.ResponseWriter, r *http.Request) {
	page, err := readPage(r)
	if err != nil {
		validationError(w, "limit", err.Error())
		return
	}
	all := s.Jobs.List()
	items, next := paginate(all, page)
	writeJSON(w, http.StatusOK, listResponse{Items: items, NextCursor: next, Total: len(all)})
}

func (s *Server) handleJobGet(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the job id is not valid")
		return
	}
	job, ok := s.Jobs.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, notFoundCode("job"), "job not found", nil)
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (s *Server) handleJobEvents(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		validationError(w, "id", "the job id is not valid")
		return
	}
	job, ok := s.Jobs.Get(id)
	if !ok {
		writeError(w, http.StatusNotFound, notFoundCode("job"), "job not found", nil)
		return
	}

	updates, unsubscribe := s.Jobs.Subscribe(id)
	defer unsubscribe()

	stream, err := sse.NewWriter(w, r)
	if err != nil {
		writeError(w, http.StatusInternalServerError, codeInternal, "streaming is not supported", nil)
		return
	}

	// Replay what the job already produced so a late subscriber sees it all.
	if err := stream.Send("status", job); err != nil {
		return
	}
	for _, line := range job.Progress {
		if err := stream.Send("progress", line); err != nil {
			return
		}
	}
	if job.FinishedAt != nil {
		_ = stream.Send("done", job)
		return
	}

	keepalive := time.NewTicker(s.KeepAlive)
	defer keepalive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case upd, ok := <-updates:
			if !ok {
				return
			}
			if upd.Line != nil {
				if err := stream.Send("progress", *upd.Line); err != nil {
					return
				}
				continue
			}
			if upd.Job.FinishedAt != nil {
				_ = stream.Send("done", upd.Job)
				return
			}
			if err := stream.Send("status", upd.Job); err != nil {
				return
			}
		case <-keepalive.C:
			if err := stream.Comment("keep-alive"); err != nil {
				return
			}
		}
	}
}
