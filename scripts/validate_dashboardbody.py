import re, json, sys
p='d:/DevOps_Projects/aws-infrastructure-monitoring/cloudformation/monitoring-stack.yaml'
s=open(p,'r',encoding='utf-8').read()
# Find the DashboardBody block after the '!Sub |' marker
m=re.search(r'DashboardBody:\s*!Sub\s*\|\n([\s\S]*?)\n\nOutputs:', s)
if not m:
    # fallback: take from 'DashboardBody' till end of file
    m=re.search(r'DashboardBody:\s*!Sub\s*\|\n([\s\S]*)$', s)
if not m:
    print('ERROR: DashboardBody block not found')
    sys.exit(2)
block=m.group(1)
# Strip leading indentation (YAML block retains indentation)
# Determine minimum indentation of non-empty lines
lines=block.splitlines()
min_indent=None
for ln in lines:
    if ln.strip():
        indent=len(ln)-len(ln.lstrip(' '))
        if min_indent is None or indent<min_indent:
            min_indent=indent
if min_indent is None:
    min_indent=0
norm_lines=[ln[min_indent:] if len(ln)>=min_indent else ln for ln in lines]
block_norm='\n'.join(norm_lines)
# Replace CloudFormation ${...} tokens with a JSON-safe string
block_norm=re.sub(r"\$\{[^}]+\}", '"DUMMY"', block_norm)
# Now try to parse JSON
try:
    json.loads(block_norm)
    print('DASHBOARD_JSON_VALID')
    sys.exit(0)
except Exception as e:
    print('DASHBOARD_JSON_INVALID')
    print('Error:', e)
    # print a short snippet for debugging
    print('\nSnippet:\n')
    print('\n'.join(norm_lines)[:2000])
    sys.exit(1)
