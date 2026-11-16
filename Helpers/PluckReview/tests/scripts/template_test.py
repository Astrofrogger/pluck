"""Renders truenas-compose.yml with sample values and checks it, plus the other docker files."""
import re, sys, yaml

docker = sys.argv[1]
ALLOWED = set("""image data media1 media1_id media2_id media2_nfs_addr media2_nfs_path uploads uploads_id
lan_addr sync_port admin_port host_key host_name role main_link backup_max backup_quality iroh
relay_token turn_secret turn_urls update_time cpus mem""".split())
SAMPLE = {k: "x" + k for k in ALLOWED}
SAMPLE.update(image="ghcr.io/example/pluck-review-host@sha256:" + "a" * 64, data="/mnt/tank/apps/pluck-review",
              media1="/mnt/tank/media", media1_id="nas1", media2_id="nas2", media2_nfs_addr="192.168.1.20",
              media2_nfs_path="/mnt/tank/media", uploads="/mnt/tank/renders", uploads_id="renders",
              lan_addr="192.168.1.10", sync_port="8790", admin_port="8791", host_name='Office "NAS"',
              role="main", backup_max="", backup_quality="", iroh="1", cpus="2.0", mem="3g", update_time="04:00")

text = open(f"{docker}/truenas-compose.yml").read()
used = set(re.findall(r"\{\{(\w+)\}\}", text))
assert used <= ALLOWED, f"unknown placeholders: {used - ALLOWED}"
assert "${" not in text, "dollar-brace found"

def render(keep):
    out, skip = [], None
    for line in text.splitlines():
        m = re.match(r"\s*# (begin|end):(\w+)\s*$", line)
        if m:
            if m.group(1) == "begin" and m.group(2) not in keep: skip = m.group(2)
            if m.group(1) == "end" and skip == m.group(2): skip = None
            continue
        if skip is None: out.append(line)
    s = "\n".join(out)
    # double-quoted YAML escaping of the value, like the filler does
    return re.sub(r"\{\{(\w+)\}\}", lambda m: SAMPLE[m.group(1)].replace("\\", "\\\\").replace('"', '\\"'), s)

for keep in (set(), {"media1"}, {"media1", "media2"}, {"uploads"}, {"media1", "media2", "uploads"}):
    doc = yaml.safe_load(render(keep))
    assert "services" in doc and "include" not in doc
    svc = doc["services"]["pluck-review"]
    assert svc["image"].startswith("ghcr.io/") and "@sha256:" in svc["image"] and ":latest" not in svc["image"]
    assert svc["user"] == "568:568" and svc["read_only"] is True and svc["network_mode"] == "host"
    env = svc["environment"]
    for k in "IROH ROLE MAIN_LINK BACKUP_MAX BACKUP_QUALITY RELAY_TOKEN TURN_SECRET TURN_URLS UPDATE_TIME HOST_KEY HOST_NAME".split():
        assert f"PLUCK_{k}" in env, k
    assert ("PLUCK_UPLOADS" in env) == ("uploads" in keep)
    assert (("volumes" in doc) and "media2" in doc["volumes"]) == ("media2" in keep)
    assert any(v.endswith("/media/nas2:ro") for v in svc["volumes"]) == ("media2" in keep)
    assert any(v.endswith("/media/nas1:ro") for v in svc["volumes"]) == ("media1" in keep)
    assert ("nas1=/media/nas1" in svc["command"]) == ("media1" in keep)
    assert all(not v.startswith("/mnt/tank/apps/") for v in svc["volumes"] if v.endswith(":ro"))
    assert any(v.startswith("/mnt/tank/renders:") for v in svc["volumes"]) == ("uploads" in keep)
    assert env["PLUCK_HOST_NAME"] == 'Office "NAS"'
    assert not re.search(r"\{\{|\$\{", render(keep))

d = yaml.safe_load(open(f"{docker}/docker-compose.yml"))
assert d["services"]["coturn"]["profiles"] == ["relay"]
c = d["services"]["coturn"]
assert c["cap_drop"] == ["ALL"] and c["read_only"] is True and c["network_mode"] == "host"
assert "@sha256:" in c["image"] and "REPLACE" not in c["image"]
assert d["services"]["pluck-review"]["build"] == {"context": "../..", "dockerfile": "PluckReview/docker/Dockerfile"}
for k in "IROH ROLE MAIN_LINK BACKUP_MAX BACKUP_QUALITY RELAY_TOKEN TURN_SECRET TURN_URLS UPDATE_TIME HOST_NAME".split():
    assert f"PLUCK_{k}" in d["services"]["pluck-review"]["environment"], k

conf = open(f"{docker}/coturn/turnserver.conf").read()
for key in "use-auth-secret no-cli no-multicast-peers no-tlsv1 no-tlsv1_1 fingerprint no-tcp-relay simple-log".split():
    assert re.search(rf"^{key}$", conf, re.M), key
for kv in "stale-nonce=600 user-quota=4 total-quota=40 max-bps=8000000 listening-port=3478 tls-listening-port=5349 min-port=49160 max-port=49200".split():
    assert re.search(rf"^{kv}$", conf, re.M), kv
# Every peer is denied; the only exception is allowed-peer-ip=${LAN_ADDR} on the command line (the NAS itself).
assert re.search(r"^denied-peer-ip=0\.0\.0\.0-255\.255\.255\.255$", conf, re.M)
assert re.search(r"^denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff$", conf, re.M)
assert not re.search(r"^allowed-peer-ip", conf, re.M)
assert not any("static-auth-secret" in str(a) for a in c.get("command", [])), "the TURN secret stays off the command line"
print("templates ok")
