"""Read-only integrity and project-reference checks; Python standard library only."""
from pathlib import Path
import hashlib,json,re

root=Path(__file__).resolve().parent.parent
bit=root/'bitstream/c14116_seed2.bit'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert bit.stat().st_size==634280
assert sha(bit)=='c495c39ef41427330c391c106ded7192ab6bc0b5b0ed879b5f91e58783af212a'
manifest=json.loads((root/'evidence/source_integrity.json').read_text(encoding='utf-8-sig'))
for item in manifest['files']:
    assert sha(root/item['path'])==item['published_sha256'],item['path']
project=root/'fpga/src/td_project/AC201_tf_hdmi.al'
# TD uses XML-like syntax with literal P&R labels, so inspect File paths directly.
for relative in re.findall(r'<File\s+Path="([^"]+)"',project.read_text(encoding='utf-8')):
    assert (project.parent/relative).exists(),relative
physical=(root/'fpga/scripts/build_manual_phy.tcl').read_text(encoding='utf-8')
assert 'set_param place seed 2' in physical
assert 'set_param flow enable_seed on' in physical
assert (root/'fpga/src/user_source/hdl_source/jpeg/LICENSE').exists()
print(f'PASS: seed2 bit SHA256, {len(manifest["files"])} source hashes, TD file references and seed2 strategy')
