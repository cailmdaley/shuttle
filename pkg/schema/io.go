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
	Path        string     // absolute path to the .md file
	Block       *Block     // parsed shuttle: block, or nil if absent
	rawContent  []byte     // full file bytes as-read
	bodyStart   int        // byte offset of the body (after closing ---)
	fmNode      *yaml.Node // parsed frontmatter document node
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
