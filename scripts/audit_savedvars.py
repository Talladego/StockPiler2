#!/usr/bin/env python3
"""Offline structural audit of StockPiler2 SavedVariables.lua (regex + brace extract)."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def extract_assignment_body(text: str, root: str) -> str:
    m = re.search(rf"{re.escape(root)}\s*=\s*\{{", text)
    if not m:
        raise SystemExit(f"no {root}")
    start = m.end() - 1
    depth = 0
    i = start
    in_str = False
    str_ch = ""
    escape = False
    while i < len(text):
        c = text[i]
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == str_ch:
                in_str = False
        else:
            if c in ("\"", "'"):
                # handle L"..." by treating L as outside
                in_str = True
                str_ch = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return text[start : i + 1]
        i += 1
    raise SystemExit(f"unbalanced {root}")


def section_body(parent: str, name: str) -> str | None:
    m = re.search(rf"(?m)^[\t ]*{re.escape(name)}\s*=\s*\{{", parent)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    i = start
    in_str = False
    str_ch = ""
    escape = False
    while i < len(parent):
        c = parent[i]
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == str_ch:
                in_str = False
        else:
            if c in ("\"", "'"):
                in_str = True
                str_ch = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return parent[start : i + 1]
        i += 1
    return None


def top_keys(body: str) -> list[str]:
    # immediate children of root object: indent one tab then key =
    keys = []
    for m in re.finditer(r"(?m)^\t([A-Za-z_][A-Za-z0-9_]*)\s*=", body):
        keys.append(m.group(1))
    return keys


def quoted_keys_at_depth2(section: str) -> list[str]:
    # keys like \t\t["uid:123"] = or \t\t["fingerprint"] =
    return re.findall(r'(?m)^\t\t\["([^"]+)"\]\s*=', section)


def numeric_keys_at_depth2(section: str) -> list[str]:
    return re.findall(r"(?m)^\t\t\[(\d+)\]\s*=", section)


def extract_recipe_keys_from_potion_block(block: str) -> list[str]:
    m = re.search(r"recipeKeys\s*=\s*\{", block)
    if not m:
        return []
    # find matching brace for recipeKeys
    start = m.end() - 1
    depth = 0
    i = start
    in_str = False
    str_ch = ""
    escape = False
    while i < len(block):
        c = block[i]
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == str_ch:
                in_str = False
        else:
            if c in ("\"", "'"):
                in_str = True
                str_ch = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    inner = block[start : i + 1]
                    return re.findall(r'"([^"]+)"', inner)
        i += 1
    return []


def split_depth2_entries(section: str) -> list[tuple[str, str]]:
    """Return (key, entry_body) for each \t\t[key] = { ... } entry."""
    entries = []
    for m in re.finditer(r'(?m)^\t\t(?:\["([^"]+)"\]|\[(\d+)\])\s*=\s*\{', section):
        key = m.group(1) if m.group(1) is not None else m.group(2)
        start = m.end() - 1
        depth = 0
        i = start
        in_str = False
        str_ch = ""
        escape = False
        while i < len(section):
            c = section[i]
            if in_str:
                if escape:
                    escape = False
                elif c == "\\":
                    escape = True
                elif c == str_ch:
                    in_str = False
            else:
                if c in ("\"", "'"):
                    in_str = True
                    str_ch = c
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        entries.append((key, section[start : i + 1]))
                        break
            i += 1
    return entries


def audit_account(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    body = extract_assignment_body(text, "StockPiler2.Account")
    out: list[str] = []
    keys = top_keys(body)
    expected = {
        "accountVersion",
        "items",
        "grows",
        "refines",
        "recipes",
        "potions",
        "additives",
        "vendorItems",
    }
    extra = [k for k in keys if k not in expected]
    missing = [k for k in expected if k not in keys and k != "accountVersion"]
    out.append(f"top keys: {keys}")
    out.append(f"EXTRA: {extra or '(none)'} MISSING sections: {missing or '(none)'}")
    av = re.search(r"accountVersion\s*=\s*(\d+)", body)
    out.append(f"accountVersion={av.group(1) if av else '?'}")

    sections = {}
    for name in ("potions", "recipes", "items", "grows", "refines", "additives", "vendorItems"):
        sec = section_body(body, name)
        sections[name] = sec or ""
        if not sec:
            out.append(f"{name}: MISSING")
            continue
        q = quoted_keys_at_depth2(sec)
        n = numeric_keys_at_depth2(sec)
        out.append(f"{name}: quotedKeys={len(q)} numericKeys={len(n)}")

    potions = split_depth2_entries(sections.get("potions") or "")
    recipes = split_depth2_entries(sections.get("recipes") or "")
    recipe_set = {k for k, _ in recipes}
    potion_set = {k for k, _ in potions}

    linked: set[str] = set()
    empty_keys = 0
    dangling = []
    active_dangling = []
    for pk, block in potions:
        rks = extract_recipe_keys_from_potion_block(block)
        if not rks:
            empty_keys += 1
        for rk in rks:
            linked.add(rk)
            if rk not in recipe_set:
                dangling.append((pk, rk))
        m = re.search(r'activeRecipeKey\s*=\s*"([^"]+)"', block)
        if m and m.group(1) not in recipe_set:
            active_dangling.append((pk, m.group(1)))

    orphan_recipes = [rk for rk, _ in recipes if rk not in linked]
    out.append(
        f"mapping: potions={len(potions)} recipes={len(recipes)} "
        f"orphansEmptyRecipeKeys={empty_keys} danglingLinks={len(dangling)} "
        f"orphanRecipes={len(orphan_recipes)} activeRecipeKeyDangling={len(active_dangling)}"
    )
    for pk, rk in dangling[:8]:
        out.append(f"  DANGLING link potion={pk} rk={rk[:70]}...")
    for pk, rk in active_dangling[:5]:
        out.append(f"  DANGLING activeRecipeKey potion={pk}")
    for rk in orphan_recipes[:8]:
        out.append(f"  ORPHAN recipe (no potion recipeKeys): {rk[:70]}...")

    # grows / refines sanity
    grows = split_depth2_entries(sections.get("grows") or "")
    refines = split_depth2_entries(sections.get("refines") or "")
    miss_seed = 0
    for k, block in grows:
        if not re.search(r"seedUid\s*=\s*\d+", block):
            miss_seed += 1
    miss_plant = 0
    for k, block in refines:
        if not re.search(r"plantUid\s*=\s*\d+", block):
            miss_plant += 1
    out.append(f"grows={len(grows)} missingSeedUid={miss_seed} refines={len(refines)} missingPlantUid={miss_plant}")

    # Item name lookup for relatedness report
    items_entries = split_depth2_entries(sections.get("items") or "")
    item_names: dict[str, str] = {}
    for ik, iblock in items_entries:
        nm = re.search(r'name\s*=\s*L?"([^"]*)"', iblock)
        if nm:
            item_names[ik] = nm.group(1)

    def normalize_grow_name(name: str) -> str:
        """Mirror SeedMap.NormalizeGrowName strip order."""
        s = (name or "").lower()
        for p in ("bunched ", "eternal ", "exceptional "):
            if s.startswith(p):
                s = s[len(p) :]
        for suf in (" seed packet", " spore packet", " seed", " spore"):
            if s.endswith(suf):
                s = s[: -len(suf)]
        if s.endswith("seed"):
            s = s[:-4]
        if s.endswith("spore"):
            s = s[:-5]
        for suf in (" powder", " extract", " blood", " dust", " oil", " pulp"):
            if s.endswith(suf):
                s = s[: -len(suf)]
        return re.sub(r"\s+", " ", s).strip()

    def genus_token(name: str) -> str:
        n = normalize_grow_name(name)
        if not n:
            return ""
        parts = n.split()
        return parts[-1] if parts else n

    def genus_related(a: str, b: str) -> bool:
        na, nb = normalize_grow_name(a), normalize_grow_name(b)
        if not na or not nb:
            return False
        if na == nb or na.replace(" ", "") == nb.replace(" ", ""):
            return True
        ga, gb = genus_token(a), genus_token(b)
        return ga != "" and ga == gb

    polluted = 0
    zero_sample = 0
    for seed_key, gblock in grows:
        sn = item_names.get(seed_key, "?")
        for pm in re.finditer(r'\["(\d+)"\]\s*=\s*\{([^}]*)\}', gblock):
            plant_key, prow = pm.group(1), pm.group(2)
            pn = item_names.get(plant_key, "?")
            sm = re.search(r"samples\s*=\s*(\d+)", prow)
            samples = int(sm.group(1)) if sm else -1
            if samples == 0:
                zero_sample += 1
            if sn != "?" and pn != "?" and not genus_related(sn, pn):
                polluted += 1
                if polluted <= 12:
                    out.append(
                        f"  POLLUTED grow seed={seed_key} ({sn}) -> plant={plant_key} ({pn}) samples={samples}"
                    )
    out.append(f"growsRelatedness: pollutedPairs={polluted} zeroSampleRows={zero_sample}")

    bad_refine = 0
    for plant_key, rblock in refines:
        pn = item_names.get(plant_key, "?")
        su = re.search(r"seedUid\s*=\s*(\d+)", rblock)
        seed_uid = su.group(1) if su else "0"
        sn = item_names.get(seed_uid, "?") if seed_uid != "0" else ""
        best_uid, best_samples = None, -1
        seed_out = re.search(r"seedOut\s*=\s*\{(.*?)\n\t\t\t\}", rblock, re.S)
        if seed_out:
            for ou, ob in re.findall(r'\["(\d+)"\]\s*=\s*\{([^}]*)\}', seed_out.group(1)):
                sm = re.search(r"samples\s*=\s*(\d+)", ob)
                samples = int(sm.group(1)) if sm else 0
                if samples > best_samples:
                    best_samples = samples
                    best_uid = ou
        if seed_uid != "0" and sn and pn != "?" and not genus_related(pn, sn):
            bad_refine += 1
            out.append(
                f"  BAD refine seedUid plant={plant_key} ({pn}) -> seed={seed_uid} ({sn}) "
                f"bestSeedOut={best_uid}({best_samples})"
            )
        elif best_uid and seed_uid != "0" and best_uid != seed_uid and best_samples > 0:
            out.append(
                f"  MISMATCH refine preferred plant={plant_key} ({pn}) seedUid={seed_uid} ({sn}) "
                f"bestOut={best_uid}({best_samples}) ({item_names.get(best_uid, '?')})"
            )
    out.append(f"refinesRelatedness: badSeedUid={bad_refine}")

    # underscore field names in persisted data
    unders = sorted(set(re.findall(r"\b(_[A-Za-z0-9_]+)\s*=", body)))
    out.append(f"underscore field names: {unders or '(none)'}")

    # mixed key types for same section (items often numeric)
    items = sections.get("items") or ""
    out.append(
        f"items quoted={len(quoted_keys_at_depth2(items))} numeric={len(numeric_keys_at_depth2(items))}"
    )

    return out, potion_set, recipe_set


def audit_settings(path: Path, potion_set: set[str], recipe_set: set[str]) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    body = extract_assignment_body(text, "StockPiler2.Settings")
    out: list[str] = []
    keys = top_keys(body)
    out.append(f"top keys: {keys}")
    known = {
        "settingsVersion",
        "charactersVersion",
        "characters",
        "debugEnabled",
        "eventTrace",
        "language",
        "selectedTab",
        "potionNameFilter",
        "potionEffectFilter",
        "potionKnownRecipeOnly",
        "potionSortColumn",
        "potionSortAscending",
        "perfEnabled",
    }
    extra = [k for k in keys if k not in known]
    out.append(f"EXTRA settings keys: {extra or '(none)'}")

    chars_sec = section_body(body, "characters") or ""
    # character buckets: \t\tName =
    char_keys = re.findall(r"(?m)^\t\t([A-Za-z0-9_^]+)\s*=", chars_sec)
    out.append(f"characterBuckets={len(char_keys)} keys={char_keys}")
    for ck in char_keys:
        if "^" in ck:
            out.append(f"  REALM MARKUP in character key: {ck}")

    # watches inside each character — find watches = { blocks at depth 3
    for m in re.finditer(
        r"(?m)^\t\t([A-Za-z0-9_^]+)\s*=\s*\{",
        chars_sec,
    ):
        ckey = m.group(1)
        # extract character bucket
        start = m.end() - 1
        depth = 0
        i = start
        in_str = False
        str_ch = ""
        escape = False
        bucket = ""
        while i < len(chars_sec):
            c = chars_sec[i]
            if in_str:
                if escape:
                    escape = False
                elif c == "\\":
                    escape = True
                elif c == str_ch:
                    in_str = False
            else:
                if c in ("\"", "'"):
                    in_str = True
                    str_ch = c
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        bucket = chars_sec[start : i + 1]
                        break
            i += 1
        watches_sec = section_body("{\n" + bucket[1:], "watches")
        # section_body expects parent with name = { at line start; hack:
        wm = re.search(r"watches\s*=\s*\{", bucket)
        if not wm:
            out.append(f"character {ckey}: no watches table")
            continue
        wstart = wm.end() - 1
        depth = 0
        i = wstart
        in_str = False
        str_ch = ""
        escape = False
        wbody = ""
        while i < len(bucket):
            c = bucket[i]
            if in_str:
                if escape:
                    escape = False
                elif c == "\\":
                    escape = True
                elif c == str_ch:
                    in_str = False
            else:
                if c in ("\"", "'"):
                    in_str = True
                    str_ch = c
                elif c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        wbody = bucket[wstart : i + 1]
                        break
            i += 1
        wkeys = re.findall(r'\["(uid:\d+\|rk:[^"]+)"\]', wbody)
        enabled = len(re.findall(r"enabled\s*=\s*true", wbody))
        unknown = 0
        dangling_rk = 0
        for wk in wkeys:
            mm = re.match(r"uid:(\d+)\|rk:(.*)$", wk)
            if not mm:
                continue
            uid = mm.group(1)
            rk = mm.group(2)
            if f"uid:{uid}" not in potion_set:
                unknown += 1
            if rk not in recipe_set:
                dangling_rk += 1
        out.append(
            f"character {ckey}: watches={len(wkeys)} enabledTrueApprox={enabled} "
            f"unknownPotionUid={unknown} danglingRecipeKey={dangling_rk}"
        )
        if unknown and unknown <= 3:
            pass
        if dangling_rk:
            # sample first dangling
            for wk in wkeys:
                mm = re.match(r"uid:(\d+)\|rk:(.*)$", wk)
                if mm and mm.group(2) not in recipe_set:
                    out.append(f"  DANGLING watch rk uid={mm.group(1)} rk={mm.group(2)[:60]}...")
                    break
    return out


def main() -> int:
    acct_path = Path(r"C:\Games\Return of Reckoning\user\settings\GLOBAL\StockPiler2\SavedVariables.lua")
    set_path = Path(
        r"C:\Games\Return of Reckoning\user\settings\Martyrs Square\SharedProfile\SharedProfile\StockPiler2\SavedVariables.lua"
    )
    print("=== Account ===")
    lines, potion_set, recipe_set = audit_account(acct_path)
    for line in lines:
        print(" ", line)
    print("\n=== Settings ===")
    for line in audit_settings(set_path, potion_set, recipe_set):
        print(" ", line)

    for bak_name in (
        "SavedVariables.lua.bak_cleanup",
        "SavedVariables.lua.bak-packet-20260907",
    ):
        bak = acct_path.with_name(bak_name)
        if bak.exists():
            print(f"\n=== {bak_name} ({bak.stat().st_size} bytes) ===")
            snippet = bak.read_text(encoding="utf-8", errors="replace")[:400]
            print(" ", snippet.replace("\n", " | "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
