package traefik_plugin_custom404

import (
	"context"
	"net/http"
	"os"
	"strconv"
)

// Config holds the plugin configuration.
type Config struct {
	FilePath string `json:"filePath,omitempty"`
}

// CreateConfig creates the default plugin configuration.
func CreateConfig() *Config {
	return &Config{
		FilePath: "/etc/traefik/html/404.html",
	}
}

// Custom404 is a Traefik middleware plugin.
type Custom404 struct {
	next     http.Handler
	name     string
	filePath string
	content  []byte
}

// New creates a new Custom404 middleware.
func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	var content []byte
	if config != nil && config.FilePath != "" {
		data, err := os.ReadFile(config.FilePath)
		if err == nil {
			content = data
		}
	}
	if len(content) == 0 {
		content = []byte("404 page not found\n")
	}

	return &Custom404{
		next:     next,
		name:     name,
		filePath: config.FilePath,
		content:  content,
	}, nil
}

func (c *Custom404) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	rw.Header().Set("Content-Type", "text/html; charset=utf-8")
	rw.Header().Set("Content-Length", strconv.Itoa(len(c.content)))
	rw.WriteHeader(http.StatusNotFound)
	_, _ = rw.Write(c.content)
}
