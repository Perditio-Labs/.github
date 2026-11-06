import os, subprocess, sys, yaml
ref = os.environ.get("MILESTONE_TEST_REF")
if ref:
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    rel = os.path.relpath(sys.argv[1], root).replace(os.sep, "/")
    source = subprocess.check_output(["git", "show", f"{ref}:{rel}"], cwd=root, text=True)
else:
    source = open(sys.argv[1], encoding="utf-8").read()
d = yaml.safe_load(source)
job = list(d["jobs"].values())[0]
step = [s for s in job["steps"] if "github-script" in s.get("uses", "")][0]
sys.stdout.write(__import__("json").dumps(step["with"]["script"]))
