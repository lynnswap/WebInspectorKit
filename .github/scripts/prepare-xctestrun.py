#!/usr/bin/env python3
"""Enable native runtime smoke tests in the generated test plan."""

import argparse
import plistlib
from pathlib import Path


def prepare(products, product):
    candidates = list(products.glob("*.xctestrun"))
    if len(candidates) != 1:
        raise ValueError(f"Expected one generated test plan in {products}, found {len(candidates)}")
    path = candidates[0]
    if product == "native":
        data = plistlib.loads(path.read_bytes())
        if "TestConfigurations" in data:
            targets = [target for configuration in data["TestConfigurations"]
                       for target in configuration["TestTargets"]]
        else:
            targets = [target for target in data.values()
                       if isinstance(target, dict) and "TestBundlePath" in target]
        for target in targets:
            target.setdefault("EnvironmentVariables", {})["WEBINSPECTORKIT_RUN_NATIVE_RUNTIME_SMOKE"] = "1"
        path.write_bytes(plistlib.dumps(data))
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", type=Path)
    parser.add_argument("--product", required=True, choices=["native", "workspace"])
    args = parser.parse_args()
    print(prepare(args.products, args.product))
