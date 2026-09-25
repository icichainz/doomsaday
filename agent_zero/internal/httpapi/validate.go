package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Input limits. Everything the API accepts is bounded.
const (
	maxLimit     = 200
	defaultLimit = 50
	maxQueryLen  = 256
	maxTailLines = 10000
	maxStopWait  = 600
)

var (
	// dockerIDRe matches a container, image, network, service or task id, or
	// a container name.
	dockerIDRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,127}$`)
	// resourceNameRe matches a volume or network name the caller creates.
	resourceNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$`)
	// imageRefRe is a conservative image reference: registry, path, tag or
	// digest. It deliberately rejects anything that could look like a flag.
	imageRefRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_.:/@-]{0,254}$`)
	// driverRe matches a volume or network driver name.
	driverRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,31}$`)
)

// validID checks a Docker identifier taken from the path.
func validID(s string) bool { return dockerIDRe.MatchString(s) }

// validImageRef checks an image reference before it reaches Docker.
func validImageRef(s string) bool {
	if !imageRefRe.MatchString(s) {
		return false
	}
	if strings.Contains(s, "..") || strings.HasPrefix(s, "-") {
		return false
	}
	return true
}

// validSubnet checks a CIDR.
func validSubnet(s string) bool {
	ip, ipnet, err := net.ParseCIDR(s)
	if err != nil {
		return false
	}
	return ip != nil && ipnet != nil
}

// decodeJSON reads a bounded JSON body into v, rejecting unknown fields.
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	ct := r.Header.Get("Content-Type")
	if ct != "" {
		if mt, _, _ := strings.Cut(ct, ";"); strings.TrimSpace(mt) != "application/json" {
			writeError(w, http.StatusUnsupportedMediaType, codeBadRequest,
				"the request body must be application/json", nil)
			return errHandled
		}
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, codePayloadTooLarge,
				"the request body is too large", nil)
			return errHandled
		}
		if errors.Is(err, io.EOF) {
			writeError(w, http.StatusBadRequest, codeBadRequest, "a JSON body is required", nil)
			return errHandled
		}
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"the request body is not valid JSON: "+err.Error(), nil)
		return errHandled
	}
	// Reject trailing content so a body cannot smuggle a second document.
	if err := dec.Decode(new(json.RawMessage)); err != io.EOF {
		writeError(w, http.StatusBadRequest, codeBadRequest,
			"the request body must hold exactly one JSON document", nil)
		return errHandled
	}
	return nil
}

// errHandled signals that the response has already been written.
var errHandled = errors.New("httpapi: response already written")

// queryInt reads a bounded integer query parameter.
func queryInt(r *http.Request, name string, def, min, max int) (int, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number", name)
	}
	if n < min || n > max {
		return 0, fmt.Errorf("%s must be between %d and %d", name, min, max)
	}
	return n, nil
}

// queryBool reads a boolean query parameter.
func queryBool(r *http.Request, name string) (bool, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return false, nil
	}
	b, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", name)
	}
	return b, nil
}

// queryTime reads an RFC 3339 timestamp, also accepting a Unix second count.
func queryTime(r *http.Request, name string) (time.Time, error) {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	if raw == "" {
		return time.Time{}, nil
	}
	if t, err := time.Parse(time.RFC3339, raw); err == nil {
		return t.UTC(), nil
	}
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil && n > 0 {
		return time.Unix(n, 0).UTC(), nil
	}
	return time.Time{}, fmt.Errorf("%s must be an RFC 3339 timestamp", name)
}

// pageParams are the shared list parameters.
type pageParams struct {
	Limit  int
	Offset int
}

// readPage parses ?limit= and ?cursor=.
func readPage(r *http.Request) (pageParams, error) {
	limit, err := queryInt(r, "limit", defaultLimit, 1, maxLimit)
	if err != nil {
		return pageParams{}, err
	}
	offset := 0
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		n, err := decodeCursor(raw)
		if err != nil {
			return pageParams{}, errors.New("cursor is not valid")
		}
		offset = n
	}
	return pageParams{Limit: limit, Offset: offset}, nil
}

func encodeCursor(offset int) string {
	return base64.RawURLEncoding.EncodeToString([]byte("o:" + strconv.Itoa(offset)))
}

func decodeCursor(s string) (int, error) {
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return 0, err
	}
	rest, ok := strings.CutPrefix(string(raw), "o:")
	if !ok {
		return 0, errors.New("bad cursor")
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n < 0 {
		return 0, errors.New("bad cursor")
	}
	return n, nil
}

// listResponse is the envelope every paginated list uses. Summary is the
// optional block a few lists carry beside items; it is computed over the
// whole host, after filtering and before paging, and is left out entirely by
// the lists that have none.
type listResponse struct {
	Items      any    `json:"items"`
	NextCursor string `json:"next_cursor,omitempty"`
	Total      int    `json:"total"`
	Summary    any    `json:"summary,omitempty"`
}

// paginate slices items and returns the page plus the next cursor.
func paginate[T any](items []T, p pageParams) ([]T, string) {
	if p.Offset >= len(items) {
		return []T{}, ""
	}
	end := p.Offset + p.Limit
	if end >= len(items) {
		return items[p.Offset:], ""
	}
	return items[p.Offset:end], encodeCursor(end)
}

// containsFold reports whether haystack contains needle, ignoring case.
func containsFold(haystack, needle string) bool {
	return strings.Contains(strings.ToLower(haystack), strings.ToLower(needle))
}
