package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

var (
	identityDaemonURLs []string
	ulidPattern        = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)
)

type identityReport struct {
	GeneratedAt time.Time              `json:"generated_at"`
	Daemons     []identityDaemonReport `json:"daemons"`
	Summary     identitySummary        `json:"summary"`
}

type identitySummary struct {
	DaemonCount       int `json:"daemon_count"`
	FiberCount        int `json:"fiber_count"`
	MissingUIDCount   int `json:"missing_uid_count"`
	DocumentSkewCount int `json:"document_skew_count"`
	DuplicateUIDCount int `json:"duplicate_uid_count"`
	RuntimeSkewCount  int `json:"runtime_skew_count"`
	HostlessOpenCount int `json:"hostless_open_count"`
}

type identityDaemonReport struct {
	URL           string                   `json:"url"`
	Host          string                   `json:"host,omitempty"`
	FiberCount    int                      `json:"fiber_count"`
	MissingUID    []identityFiberFinding   `json:"missing_uid,omitempty"`
	DocumentSkew  []identityFiberFinding   `json:"document_skew,omitempty"`
	DuplicateUIDs []identityDuplicateUID   `json:"duplicate_uids,omitempty"`
	RuntimeSkew   []identityRuntimeFinding `json:"runtime_skew,omitempty"`
	HostlessOpen  []identityFiberFinding   `json:"hostless_open,omitempty"`
	Error         string                   `json:"error,omitempty"`
}

type identityFiberFinding struct {
	Slug      string `json:"slug,omitempty"`
	ID        string `json:"id,omitempty"`
	UID       string `json:"uid,omitempty"`
	Status    string `json:"status,omitempty"`
	FeltStore string `json:"felt_store,omitempty"`
	Path      string `json:"path,omitempty"`
	Host      string `json:"host,omitempty"`
}

type identityDuplicateUID struct {
	UID   string                 `json:"uid"`
	Rows  []identityFiberFinding `json:"rows"`
	Count int                    `json:"count"`
}

type identityRuntimeFinding struct {
	Key     string `json:"key"`
	UID     string `json:"uid,omitempty"`
	FiberID string `json:"fiber_id,omitempty"`
	Reason  string `json:"reason"`
}

type daemonFibersResponse struct {
	Host   string           `json:"host"`
	Fibers []daemonFiberRow `json:"fibers"`
}

type daemonFiberRow struct {
	Path      string         `json:"path"`
	FeltStore string         `json:"felt_store"`
	Fiber     map[string]any `json:"fiber"`
}

type daemonStateResponse struct {
	Runtime map[string]map[string]any `json:"runtime"`
}

var validateIdentityCmd = &cobra.Command{
	Use:   "validate-identity",
	Short: "Validate federated fiber UID readiness across daemon feeds",
	Long: `Queries Shuttle daemon document and runtime surfaces and checks the
intrinsic-identity migration invariants:

  - /api/v1/fibers rows carry ULID uid values
  - document id equals uid when uid is present
  - uid values do not describe multiple slug addresses in one daemon feed
  - /api/v1/state.runtime rows are keyed by uid when a uid is present
  - open/active shuttle fibers have shuttle.host ownership

By default it checks the usual local tunnel ports (:4000, :4001, :4002).
Pass --daemon-url repeatedly to validate another set of daemon base URLs.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		urls := identityDaemonURLs
		if len(urls) == 0 {
			urls = []string{
				"http://127.0.0.1:4000",
				"http://127.0.0.1:4001",
				"http://127.0.0.1:4002",
			}
		}

		report := validateIdentity(urls)
		hasGaps := report.Summary.MissingUIDCount > 0 ||
			report.Summary.DocumentSkewCount > 0 ||
			report.Summary.DuplicateUIDCount > 0 ||
			report.Summary.RuntimeSkewCount > 0 ||
			report.Summary.HostlessOpenCount > 0

		if jsonOutput {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			if err := enc.Encode(report); err != nil {
				return err
			}
			if hasGaps {
				return fmt.Errorf("identity validation found gaps")
			}
			return nil
		}

		printIdentityReport(report)
		if hasGaps {
			return fmt.Errorf("identity validation found gaps")
		}
		return nil
	},
}

func validateIdentity(urls []string) identityReport {
	report := identityReport{GeneratedAt: time.Now().UTC()}
	for _, url := range urls {
		daemon := validateIdentityDaemon(strings.TrimRight(url, "/"))
		report.Daemons = append(report.Daemons, daemon)
		report.Summary.DaemonCount++
		report.Summary.FiberCount += daemon.FiberCount
		report.Summary.MissingUIDCount += len(daemon.MissingUID)
		report.Summary.DocumentSkewCount += len(daemon.DocumentSkew)
		report.Summary.DuplicateUIDCount += len(daemon.DuplicateUIDs)
		report.Summary.RuntimeSkewCount += len(daemon.RuntimeSkew)
		report.Summary.HostlessOpenCount += len(daemon.HostlessOpen)
	}
	return report
}

func validateIdentityDaemon(baseURL string) identityDaemonReport {
	report := identityDaemonReport{URL: baseURL}

	var fibers daemonFibersResponse
	if err := fetchJSON(baseURL+"/api/v1/fibers?shuttle=true", &fibers); err != nil {
		report.Error = err.Error()
		return report
	}
	report.Host = fibers.Host
	report.FiberCount = len(fibers.Fibers)

	byUID := map[string][]identityFiberFinding{}
	for _, row := range fibers.Fibers {
		finding := identityFindingFromRow(row)
		if finding.UID == "" || !ulidPattern.MatchString(finding.UID) {
			report.MissingUID = append(report.MissingUID, finding)
		} else {
			byUID[finding.UID] = append(byUID[finding.UID], finding)
		}
		if finding.UID != "" && finding.ID != finding.UID {
			report.DocumentSkew = append(report.DocumentSkew, finding)
		}
		if isOpenStatus(finding.Status) && finding.Host == "" {
			report.HostlessOpen = append(report.HostlessOpen, finding)
		}
	}

	for uid, rows := range byUID {
		if duplicateIdentityRows(rows) {
			report.DuplicateUIDs = append(report.DuplicateUIDs, identityDuplicateUID{
				UID:   uid,
				Rows:  rows,
				Count: len(rows),
			})
		}
	}
	sortIdentityDaemonReport(&report)

	var state daemonStateResponse
	if err := fetchJSON(baseURL+"/api/v1/state", &state); err != nil {
		report.RuntimeSkew = append(report.RuntimeSkew, identityRuntimeFinding{
			Reason: "state fetch failed: " + err.Error(),
		})
		return report
	}
	for key, row := range state.Runtime {
		uid := stringField(row, "uid")
		if uid == "" {
			report.RuntimeSkew = append(report.RuntimeSkew, identityRuntimeFinding{
				Key:     key,
				FiberID: stringField(row, "fiber_id"),
				Reason:  "runtime row missing uid",
			})
			continue
		}
		if key != uid {
			report.RuntimeSkew = append(report.RuntimeSkew, identityRuntimeFinding{
				Key:     key,
				UID:     uid,
				FiberID: stringField(row, "fiber_id"),
				Reason:  "runtime key differs from uid",
			})
		}
	}
	sort.Slice(report.RuntimeSkew, func(i, j int) bool {
		return report.RuntimeSkew[i].Key < report.RuntimeSkew[j].Key
	})

	return report
}

func identityFindingFromRow(row daemonFiberRow) identityFiberFinding {
	shuttle, _ := row.Fiber["shuttle"].(map[string]any)
	id := stringField(row.Fiber, "id")
	slug := stringField(row.Fiber, "slug")
	if slug == "" && !ulidPattern.MatchString(id) {
		slug = id
	}
	return identityFiberFinding{
		Slug:      slug,
		ID:        id,
		UID:       stringField(row.Fiber, "uid"),
		Status:    stringField(row.Fiber, "status"),
		FeltStore: row.FeltStore,
		Path:      row.Path,
		Host:      stringField(shuttle, "host"),
	}
}

func duplicateIdentityRows(rows []identityFiberFinding) bool {
	if len(rows) < 2 {
		return false
	}
	first := rows[0].Slug
	for _, row := range rows[1:] {
		if row.Slug != first {
			return true
		}
	}
	return false
}

func sortIdentityDaemonReport(report *identityDaemonReport) {
	sortFindings(report.MissingUID)
	sortFindings(report.DocumentSkew)
	sortFindings(report.HostlessOpen)
	sort.Slice(report.DuplicateUIDs, func(i, j int) bool {
		return report.DuplicateUIDs[i].UID < report.DuplicateUIDs[j].UID
	})
}

func sortFindings(rows []identityFiberFinding) {
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Slug != rows[j].Slug {
			return rows[i].Slug < rows[j].Slug
		}
		return rows[i].FeltStore < rows[j].FeltStore
	})
}

func fetchJSON(url string, dest any) error {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("reaching %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s returned %d", url, resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(dest); err != nil {
		return fmt.Errorf("decoding %s: %w", url, err)
	}
	return nil
}

func stringField(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	value, _ := m[key].(string)
	return value
}

func isOpenStatus(status string) bool {
	return status == "open" || status == "active"
}

func printIdentityReport(report identityReport) {
	fmt.Printf("Federated identity validation (%s)\n", report.GeneratedAt.Format(time.RFC3339))
	fmt.Printf("Daemons: %d  Fibers: %d  Missing UID: %d  Document skew: %d  Duplicate UID: %d  Runtime skew: %d  Hostless open: %d\n\n",
		report.Summary.DaemonCount,
		report.Summary.FiberCount,
		report.Summary.MissingUIDCount,
		report.Summary.DocumentSkewCount,
		report.Summary.DuplicateUIDCount,
		report.Summary.RuntimeSkewCount,
		report.Summary.HostlessOpenCount,
	)

	for _, daemon := range report.Daemons {
		host := daemon.Host
		if host == "" {
			host = "(unknown)"
		}
		fmt.Printf("%s (%s): %d fibers\n", daemon.URL, host, daemon.FiberCount)
		if daemon.Error != "" {
			fmt.Printf("  error: %s\n\n", daemon.Error)
			continue
		}
		printFindingGroup("missing uid", daemon.MissingUID)
		printFindingGroup("document id != uid", daemon.DocumentSkew)
		printFindingGroup("hostless open/active", daemon.HostlessOpen)
		printDuplicateGroup(daemon.DuplicateUIDs)
		printRuntimeGroup(daemon.RuntimeSkew)
		fmt.Println()
	}
}

func printFindingGroup(label string, rows []identityFiberFinding) {
	if len(rows) == 0 {
		return
	}
	fmt.Printf("  %s (%d):\n", label, len(rows))
	for _, row := range limitFindings(rows, 12) {
		fmt.Printf("    - %s [status=%s id=%s uid=%s host=%s]\n", row.Slug, row.Status, row.ID, row.UID, row.Host)
	}
	printLimitNotice(len(rows), 12)
}

func printDuplicateGroup(rows []identityDuplicateUID) {
	if len(rows) == 0 {
		return
	}
	fmt.Printf("  duplicate uid (%d):\n", len(rows))
	for _, row := range rows {
		fmt.Printf("    - %s (%d rows)\n", row.UID, row.Count)
	}
}

func printRuntimeGroup(rows []identityRuntimeFinding) {
	if len(rows) == 0 {
		return
	}
	fmt.Printf("  runtime skew (%d):\n", len(rows))
	for _, row := range rows {
		fmt.Printf("    - key=%s uid=%s fiber_id=%s: %s\n", row.Key, row.UID, row.FiberID, row.Reason)
	}
}

func limitFindings(rows []identityFiberFinding, limit int) []identityFiberFinding {
	if len(rows) <= limit {
		return rows
	}
	return rows[:limit]
}

func printLimitNotice(count, limit int) {
	if count > limit {
		fmt.Printf("    ... %d more\n", count-limit)
	}
}

func init() {
	validateIdentityCmd.Flags().StringArrayVar(&identityDaemonURLs, "daemon-url", nil, "Daemon base URL to validate; repeat for multiple hosts")
	rootCmd.AddCommand(validateIdentityCmd)
}
