package schema

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// FiberFile wraps a fiber's file contents with its parsed shuttle: block.
type FiberFile struct {
	Path       string     // absolute path to the .md file
	Block      *Block     // parsed shuttle: block, or nil if absent
	rawContent []byte     // full file bytes as-read
	bodyStart  int        // byte offset of the body (after closing ---)
	fmNode     *yaml.Node // parsed frontmatter document node
}

// ReadFiber reads a fiber file, splits frontmatter/body, and parses the
// shuttle: block if present. The raw bytes are retained for atomic writing.
func ReadFiber(path string) (*FiberFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}

	fm, bodyStart, err := splitFrontmatter(data)
	if err != nil {
		return nil, fmt.Errorf("splitting frontmatter in %s: %w", path, err)
	}

	var docNode yaml.Node
	if err := yaml.Unmarshal(fm, &docNode); err != nil {
		return nil, fmt.Errorf("parsing frontmatter in %s: %w", path, err)
	}

	f := &FiberFile{
		Path:       path,
		rawContent: data,
		bodyStart:  bodyStart,
		fmNode:     &docNode,
	}

	// Extract shuttle: block.
	shuttleNode := findMappingValue(&docNode, "shuttle")
	if shuttleNode != nil {
		var b Block
		if err := shuttleNode.Decode(&b); err != nil {
			return nil, fmt.Errorf("decoding shuttle: block in %s: %w", path, err)
		}
		f.Block = &b
	}

	return f, nil
}

// Status returns the felt-native `status:` value from the frontmatter, or "" if
// the field is missing. The shuttle daemon's eligibility filter
// (lib/shuttle/poller.ex `eligible?/2`) requires status to be "active" or
// "open" — a missing field is treated as ineligible. Callers managing the
// dispatch lifecycle (install, resume) should ensure this is set.
func (f *FiberFile) Status() string {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return ""
	}
	statusNode := findMappingValue(f.fmNode, "status")
	if statusNode == nil || statusNode.Kind != yaml.ScalarNode {
		return ""
	}
	return statusNode.Value
}

// SetStatus mutates the felt-native `status:` field in the frontmatter. The
// change takes effect on the next WriteBlock call. Creates the field if
// absent.
func (f *FiberFile) SetStatus(status string) {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	mappingNode := f.fmNode.Content[0]
	if mappingNode.Kind != yaml.MappingNode {
		return
	}
	valueNode := &yaml.Node{Kind: yaml.ScalarNode, Value: status, Tag: "!!str"}
	setMappingValue(mappingNode, "status", valueNode)
}

// SetTempered mutates the felt-native `tempered:` field in the frontmatter.
// Pass nil to remove the field entirely.
func (f *FiberFile) SetTempered(value *bool) {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	mappingNode := f.fmNode.Content[0]
	if mappingNode.Kind != yaml.MappingNode {
		return
	}
	if value == nil {
		removeMappingKey(mappingNode, "tempered")
		return
	}
	boolValue := "false"
	if *value {
		boolValue = "true"
	}
	valueNode := &yaml.Node{Kind: yaml.ScalarNode, Value: boolValue, Tag: "!!bool"}
	setMappingValue(mappingNode, "tempered", valueNode)
}

// Tempered returns the felt-native `tempered:` value as *bool, or nil when the
// field is absent. Absent (nil) is the no-verdict state: combined with
// `status: closed` it is the new-model awaiting signal. `true`/`false` are
// verdicts (accepted oneshot terminus / composted).
func (f *FiberFile) Tempered() *bool {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return nil
	}
	node := findMappingValue(f.fmNode, "tempered")
	if node == nil || node.Kind != yaml.ScalarNode {
		return nil
	}
	switch node.Value {
	case "true":
		v := true
		return &v
	case "false":
		v := false
		return &v
	default:
		return nil
	}
}

// SetClosedAtIfMissing sets `closed-at:` only when the field is currently
// absent.
func (f *FiberFile) SetClosedAtIfMissing(value string) {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	mappingNode := f.fmNode.Content[0]
	if mappingNode.Kind != yaml.MappingNode {
		return
	}
	if existing := findMappingValue(mappingNode, "closed-at"); existing != nil {
		return
	}
	valueNode := &yaml.Node{Kind: yaml.ScalarNode, Value: value, Tag: "!!str"}
	setMappingValue(mappingNode, "closed-at", valueNode)
}

// ClearClosedAt removes the felt-native `closed-at:` field if present.
func (f *FiberFile) ClearClosedAt() {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	mappingNode := f.fmNode.Content[0]
	if mappingNode.Kind != yaml.MappingNode {
		return
	}
	removeMappingKey(mappingNode, "closed-at")
}

// SetOutcome replaces or inserts the felt-native `outcome:` field. Multi-line
// outcomes are encoded as literal block scalars so they round-trip as `|-`.
func (f *FiberFile) SetOutcome(outcome string) {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	mappingNode := f.fmNode.Content[0]
	if mappingNode.Kind != yaml.MappingNode {
		return
	}
	valueNode := &yaml.Node{Kind: yaml.ScalarNode, Value: outcome, Tag: "!!str"}
	if strings.Contains(outcome, "\n") {
		valueNode.Style = yaml.LiteralStyle
	}
	setMappingValue(mappingNode, "outcome", valueNode)
}

// RemoveTag removes a single tag value from the YAML frontmatter's `tags:` list.
// The removal happens in the in-memory yaml.Node; it takes effect on the next
// WriteBlock call. No-op if the tag is absent or the tags field doesn't exist.
func (f *FiberFile) RemoveTag(tag string) {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return
	}
	tagsNode := findMappingValue(f.fmNode, "tags")
	if tagsNode == nil || tagsNode.Kind != yaml.SequenceNode {
		return
	}
	filtered := make([]*yaml.Node, 0, len(tagsNode.Content))
	for _, item := range tagsNode.Content {
		if item.Value != tag {
			filtered = append(filtered, item)
		}
	}
	tagsNode.Content = filtered
}

// WriteBlock mutates the shuttle: key in the fiber's frontmatter YAML node and
// writes the result atomically (temp-file + rename). Creates the shuttle: key
// if absent. Removes it entirely when block is nil (uninstall).
//
// The rest of the frontmatter is preserved byte-for-byte except for whitespace
// normalisation that yaml.Node encoding may introduce.
func (f *FiberFile) WriteBlock(block *Block) error {
	if f.fmNode == nil || len(f.fmNode.Content) == 0 {
		return fmt.Errorf("empty or invalid frontmatter in %s", f.Path)
	}

	mappingNode := f.fmNode.Content[0] // document → mapping
	if mappingNode.Kind != yaml.MappingNode {
		return fmt.Errorf("frontmatter root is not a YAML mapping in %s", f.Path)
	}

	if block == nil {
		// Remove the shuttle: key if present.
		removeMappingKey(mappingNode, "shuttle")
	} else {
		// Encode block as a yaml.Node so we can splice it in.
		blockNode, err := encodeNode(block)
		if err != nil {
			return fmt.Errorf("encoding shuttle block: %w", err)
		}
		blockNode = mergeUnknownShuttleFields(findMappingValue(mappingNode, "shuttle"), blockNode)
		setMappingValue(mappingNode, "shuttle", blockNode)
	}

	// Re-serialize the modified frontmatter.
	var fmBuf bytes.Buffer
	enc := yaml.NewEncoder(&fmBuf)
	enc.SetIndent(2)
	if err := enc.Encode(f.fmNode); err != nil {
		return fmt.Errorf("encoding modified frontmatter: %w", err)
	}
	enc.Close()

	// Reconstruct: ---\n<frontmatter>\n---\n<body>
	fmBytes := bytes.TrimRight(fmBuf.Bytes(), "\n")
	body := f.rawContent[f.bodyStart:]

	var out bytes.Buffer
	out.WriteString("---\n")
	out.Write(fmBytes)
	out.WriteString("\n---\n")
	out.Write(body)

	return atomicWrite(f.Path, out.Bytes())
}

// atomicWrite writes data to path via a temp-file + rename.
// If the write or sync fails, the original file is untouched.
func atomicWrite(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".shuttle-write-*")
	if err != nil {
		return fmt.Errorf("creating temp file in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()

	// Ensure cleanup on any error path.
	success := false
	defer func() {
		if !success {
			os.Remove(tmpPath)
		}
	}()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("writing temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("syncing temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("closing temp file: %w", err)
	}

	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("renaming %s → %s: %w", tmpPath, path, err)
	}
	success = true
	return nil
}

// ---- Frontmatter splitting -------------------------------------------------

// splitFrontmatter separates the YAML frontmatter from the markdown body.
// Returns (frontmatterBytes, bodyStartOffset, error).
// The returned frontmatterBytes do NOT include the surrounding --- delimiters.
func splitFrontmatter(data []byte) ([]byte, int, error) {
	s := string(data)
	if !strings.HasPrefix(s, "---\n") && !strings.HasPrefix(s, "---\r\n") {
		return nil, 0, fmt.Errorf("missing opening --- frontmatter delimiter")
	}

	// Skip the opening ---
	rest := s[4:]
	idx := strings.Index(rest, "\n---")
	if idx < 0 {
		return nil, 0, fmt.Errorf("missing closing --- frontmatter delimiter")
	}

	fm := rest[:idx]
	// bodyStart points to just after the closing \n---\n
	closer := idx + 4 // len("\n---")
	bodyStart := 4 + closer
	if bodyStart < len(s) && s[bodyStart] == '\n' {
		bodyStart++
	}

	return []byte(fm), bodyStart, nil
}

// ---- yaml.Node helpers -----------------------------------------------------

// findMappingValue returns the value node for key in a YAML document or mapping node.
func findMappingValue(doc *yaml.Node, key string) *yaml.Node {
	var mapping *yaml.Node
	switch doc.Kind {
	case yaml.DocumentNode:
		if len(doc.Content) == 0 {
			return nil
		}
		mapping = doc.Content[0]
	case yaml.MappingNode:
		mapping = doc
	default:
		return nil
	}
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}

// setMappingValue sets key→value in a mapping node. If key exists, its value
// is replaced in-place (preserving key node position). If absent, the pair is
// appended.
func setMappingValue(mapping *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			mapping.Content[i+1] = value
			return
		}
	}
	// Append new key-value pair.
	keyNode := &yaml.Node{Kind: yaml.ScalarNode, Value: key, Tag: "!!str"}
	mapping.Content = append(mapping.Content, keyNode, value)
}

// removeMappingKey removes a key-value pair from a mapping node by key name.
func removeMappingKey(mapping *yaml.Node, key string) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			mapping.Content = append(mapping.Content[:i], mapping.Content[i+2:]...)
			return
		}
	}
}

// knownShuttleKeys are the keys mergeUnknownShuttleFields recognizes. Keys
// present here are NOT carried forward as "unknown" fields when a Go rewrite
// re-encodes the block; only keys ABSENT here are preserved. Live struct fields
// (kind, interactive, host, project_dir, agent, schedule, session) plus the
// legacy fields slice 5 dropped (enabled, review) plus daemon-owned timestamps
// (next_due_at, last_run_at) are all listed, so a Go rewrite WIPES the dropped
// fields cleanly rather than resurrecting them as unknowns (clean cutover, no
// read-tolerant preservation).
var knownShuttleKeys = map[string]bool{
	"kind":        true,
	"mode":        true, // legacy alias; rewritten to kind on the next save
	"interactive": true,
	"host":        true,
	"project_dir": true,
	"agent":       true,
	"schedule":    true,
	"session":     true,
	"enabled":     true, // legacy (slice 5): recognized so it's wiped, not preserved
	"review":      true, // legacy (slice 5): recognized so it's wiped, not preserved
	"next_due_at": true, // daemon-owned timestamp: not a struct field; wiped on Go rewrite
	"last_run_at": true, // daemon-owned timestamp: not a struct field; wiped on Go rewrite
}

// mergeUnknownShuttleFields preserves forward-compatible shuttle: keys when a
// typed Go lifecycle rewrite updates the block. Elixir is currently the wider
// schema reader/writer, so replacing the whole mapping would silently erase
// fields the Go struct does not yet know.
func mergeUnknownShuttleFields(existing, encoded *yaml.Node) *yaml.Node {
	if existing == nil || existing.Kind != yaml.MappingNode || encoded == nil || encoded.Kind != yaml.MappingNode {
		return encoded
	}

	for i := 0; i+1 < len(existing.Content); i += 2 {
		keyNode := existing.Content[i]
		valueNode := existing.Content[i+1]
		if keyNode == nil || knownShuttleKeys[keyNode.Value] || mappingHasKey(encoded, keyNode.Value) {
			continue
		}
		encoded.Content = append(encoded.Content, cloneYAMLNode(keyNode), cloneYAMLNode(valueNode))
	}

	return encoded
}

func mappingHasKey(mapping *yaml.Node, key string) bool {
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return false
	}
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return true
		}
	}
	return false
}

func cloneYAMLNode(node *yaml.Node) *yaml.Node {
	if node == nil {
		return nil
	}
	clone := *node
	if len(node.Content) > 0 {
		clone.Content = make([]*yaml.Node, len(node.Content))
		for i, child := range node.Content {
			clone.Content[i] = cloneYAMLNode(child)
		}
	}
	return &clone
}

// encodeNode marshals v into a *yaml.Node suitable for splicing into a mapping.
func encodeNode(v interface{}) (*yaml.Node, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	enc.Close()

	var doc yaml.Node
	if err := yaml.Unmarshal(buf.Bytes(), &doc); err != nil {
		return nil, err
	}
	if doc.Kind == yaml.DocumentNode && len(doc.Content) > 0 {
		return doc.Content[0], nil
	}
	return &doc, nil
}
