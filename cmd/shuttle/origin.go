package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

type Origin struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type originList struct {
	Origins []Origin `json:"origins"`
}

func normalizedOrigin() string {
	if originFlag == "" {
		return "local"
	}
	return originFlag
}

func usingLocalOrigin() bool {
	return normalizedOrigin() == "local"
}

func resolveOriginURL(name string) (string, error) {
	if name == "" || name == "local" {
		return daemonURL(), nil
	}

	origins, err := fetchOrigins()
	if err != nil {
		return "", err
	}
	for _, origin := range origins {
		if origin.Name == name {
			return strings.TrimRight(origin.URL, "/"), nil
		}
	}
	return "", fmt.Errorf("unknown origin %q; configured: %s", name, joinOriginNames(origins))
}

func fetchOrigins() ([]Origin, error) {
	url := daemonURL() + "/api/v1/origins"
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("reaching local daemon for origins at %s: %w", url, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("reading origins response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("origins endpoint returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var out originList
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("parsing origins response: %w", err)
	}
	return out.Origins, nil
}

func postRemoteLifecycle(action string, payload map[string]any) error {
	origin := normalizedOrigin()
	baseURL, err := resolveOriginURL(origin)
	if err != nil {
		return err
	}

	payload["action"] = action
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("encoding lifecycle request: %w", err)
	}

	url := baseURL + "/api/v1/lifecycle"
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("origin %q unreachable at %s: %w", origin, url, err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading lifecycle response from origin %q: %w", origin, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("origin %q returned %d: %s", origin, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	fmt.Print(string(respBody))
	return nil
}

func joinOriginNames(origins []Origin) string {
	names := make([]string, 0, len(origins))
	for _, origin := range origins {
		names = append(names, origin.Name)
	}
	sort.Strings(names)
	if len(names) == 0 {
		return "<none>"
	}
	return strings.Join(names, ", ")
}
