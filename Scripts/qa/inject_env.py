#!/usr/bin/env python3
"""Inject QA_* environment variables from the CI environment into the built xctestrun."""
import glob
import os
import plistlib
import sys


def main() -> int:
    path = glob.glob(os.environ.get("XCTRUN_GLOB", "dd/Build/Products/*-*.xctestrun"))
    if not path:
        print("no xctestrun found", file=sys.stderr)
        return 1
    path = path[0]
    print("xctestrun:", path)

    env = {k: os.environ[k] for k in ("QA_SERVER_URL", "QA_USER", "QA_PASS") if k in os.environ}
    if not env:
        print("no QA_* vars in environment", file=sys.stderr)
        return 1

    with open(path, "rb") as handle:
        data = plistlib.load(handle)

    injected = 0
    for section in data.values():
        if not isinstance(section, dict):
            continue
        test_configs = section.get("TestConfigurations")
        if not isinstance(test_configs, dict):
            continue
        test_configs.setdefault("EnvironmentVariables", {}).update(env)
        injected += 1
        for cfg in (test_configs.get("TestConfigurationData") or {}).values():
            if isinstance(cfg, dict):
                cfg.setdefault("EnvironmentVariables", {}).update(env)

    with open(path, "wb") as handle:
        plistlib.dump(data, handle)
    print(f"env injected into {injected} section(s):", ", ".join(sorted(env)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
