import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
job = list(d["jobs"].values())[0]
step = [s for s in job["steps"] if "github-script" in s.get("uses", "")][0]
sys.stdout.write(__import__("json").dumps(step["with"]["script"]))
