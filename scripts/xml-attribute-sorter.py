#!/usr/bin/env python3
import sys
import re

# Claude-generated script to sort XML attributes from AXTool output to aid in
# diffing.

EXCLUDED_ATTRIBUTES = {
    'AXFrame',
    'AXPosition',
    'AXSize',
    'AXActivationPoint'
}

def sort_attributes_in_tag(match):
    """Sort attributes in a single XML tag."""
    tag_content = match.group(0)

    # Extract tag name and attributes
    tag_match = re.match(r'^<([^>\s]+)(.*?)(/?>)$', tag_content, re.DOTALL)
    if not tag_match:
        return tag_content

    tag_name = tag_match.group(1)
    attrs_section = tag_match.group(2)
    tag_end = tag_match.group(3)

    if not attrs_section.strip():
        return tag_content

    # Find all attributes using regex
    attr_pattern = r'(\s+)([^=\s]+)(\s*=\s*(?:"[^"]*"|\'[^\']*\'|[^>\s]+))'
    attrs = re.findall(attr_pattern, attrs_section)

    if not attrs:
        return tag_content

    # Filter out excluded attributes and sort by name
    filtered_attrs = [attr for attr in attrs if attr[1] not in EXCLUDED_ATTRIBUTES]
    sorted_attrs = sorted(filtered_attrs, key=lambda x: x[1])

    # Reconstruct the tag with sorted attributes
    new_attrs_section = ''.join(f'{ws}{name}{value}' for ws, name, value in sorted_attrs)

    return f'<{tag_name}{new_attrs_section}{tag_end}'

def main():
    if len(sys.argv) != 2:
        print("Usage: python sort_xml_attributes.py <xml_file>", file=sys.stderr)
        sys.exit(1)

    xml_file = sys.argv[1]

    try:
        with open(xml_file, 'r', encoding='utf-8') as f:
            content = f.read()

        # Find all opening and self-closing tags with attributes
        tag_pattern = r'<[^!?/][^>]*?[^/]>'  # Opening tags
        self_closing_pattern = r'<[^!?/][^>]*?/>'  # Self-closing tags

        # Sort attributes in both patterns
        content = re.sub(tag_pattern, sort_attributes_in_tag, content)
        content = re.sub(self_closing_pattern, sort_attributes_in_tag, content)

        print(content, end='')

    except FileNotFoundError:
        print(f"File not found: {xml_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
