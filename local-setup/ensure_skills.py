#!/usr/bin/env python3
"""Mirror AgentKit / ClaudeKit skills into a skill root DeepSeek Harness scans.

Why a mirror instead of `ak kit install --target dsh`: AgentKit's CLI ships a
`dsh` adapter, but no kit on its registry declares that runtime yet — a remote
install fails with `unsupported runtime target "dsh"`, so nothing ever writes the
Harness's skill roots.

Why a copy instead of symlinks: `dsh-skill-filesystem` requires the frontmatter
`name` to match /^[a-z0-9]+(?:-[a-z0-9]+)*$/ and drops the whole skill otherwise.
ClaudeKit names its skills `ck:<skill>` and the cached AgentKit kits name theirs
`ak-<skill>`, so both are invisible to the Harness until the name is normalized. A
symlink cannot carry a rewritten name, so each bundle is copied and only its
frontmatter `name:` line is rewritten.

Two sources are read. `~/.claude/skills` is what the Claude Code adapter installed;
`~/.agentkit/cache/kits/**` is what AgentKit downloaded for its own adapters, and
it carries fuller variants — the `plan` bundle there holds 22 references including
`debate-mode.md` and `ultra-mode.md`, where the installed one holds 14 and
documents neither mode. When both sources declare the same skill name, the bundle
carrying more files is mirrored; a smaller variant never replaces a larger one.

The mirror is generated, never hand-edited: re-run this script after AgentKit
changes its skills and it refreshes every bundle it owns and prunes the rest.
Bundles in the destination that this script did not create are left untouched.

    python3 ~/deepseek-harness/local-setup/ensure_skills.py
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import sys

SOURCE = os.environ.get("AGENTKIT_SKILLS", os.path.expanduser("~/.claude/skills"))
KIT_CACHE = os.environ.get("AGENTKIT_KIT_CACHE", os.path.expanduser("~/.agentkit/cache/kits"))
DEST = os.environ.get("DSH_SKILLS_ROOT", os.path.expanduser("~/.dsh/skills"))
MARKER = os.path.join(DEST, ".agentkit-mirror")

# Cached kits keep their payload under <kit>/<adapter>/<version>/<name>/; the adapter's
# skill bundles live in `.omp/skills`, with a plain `skills` directory as the fallback.
KIT_SKILL_GLOBS = ("*/*/*/*/.omp/skills", "*/*/*/*/skills")

DSH_SKILL_NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
NAMESPACE = re.compile(r"^(?:ck|ak)[:\-]")
FRONTMATTER = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.DOTALL)
NAME_LINE = re.compile(r"^name:[ \t]*(\S.*?)[ \t]*$", re.MULTILINE)


def declared_name(skill_md: str) -> str | None:
    """Return the frontmatter `name` value, or None when the file has no frontmatter."""
    block = FRONTMATTER.match(skill_md)
    if block is None:
        return None
    found = NAME_LINE.search(block.group(1))
    if found is None:
        return None
    return found.group(1).strip().strip("\"'")


def normalize(name: str, directory: str) -> str | None:
    """Return a DSH-valid skill name, dropping an AgentKit namespace prefix.

    `ck:brainstorm`, `ck-plan` and `ak-plan` all become their bare skill name; a name
    that is already valid is kept. The directory name is the fallback when the
    declared name cannot be salvaged.
    """
    bare = NAMESPACE.sub("", name.rsplit(":", 1)[-1])
    for candidate in (bare, name, directory):
        if DSH_SKILL_NAME.match(candidate) and candidate:
            return candidate
    return None


def find_bundles(root: str) -> list[tuple[str, str]]:
    """Return (bundle directory, directory name) for every <name>/SKILL.md, top level first.

    `dsh-skill-filesystem` discovers only top-level bundles, so a nested bundle
    such as document-skills/pdf is collected here and mirrored as its own entry.
    """
    bundles: list[tuple[str, str]] = []
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        if not os.path.isdir(path):
            continue
        if os.path.isfile(os.path.join(path, "SKILL.md")):
            bundles.append((path, entry))
            continue
        for nested in sorted(os.listdir(path)):
            nested_path = os.path.join(path, nested)
            if os.path.isdir(nested_path) and os.path.isfile(os.path.join(nested_path, "SKILL.md")):
                bundles.append((nested_path, nested))
    return bundles


def kit_skill_roots() -> list[str]:
    """Return every skill directory inside the AgentKit kit cache."""
    roots: list[str] = []
    for pattern in KIT_SKILL_GLOBS:
        roots.extend(sorted(glob.glob(os.path.join(KIT_CACHE, pattern))))
    return roots


def bundle_weight(bundle: str) -> int:
    """Rank a bundle by the number of files it carries.

    The two sources ship different generations of the same skill; the fuller bundle is
    the one that still documents the modes the smaller one dropped.
    """
    return sum(len(files) for _root, _dirs, files in os.walk(bundle))


def previous_names() -> set[str]:
    """Return the bundle names the last run generated."""
    if not os.path.isfile(MARKER):
        return set()
    with open(MARKER, encoding="utf-8") as handle:
        return {line.strip() for line in handle if line.strip()}


def owned(path: str, name: str, previous: set[str]) -> bool:
    """Report whether this script may replace the destination entry.

    Entries it generated before, and any symlink, are owned; anything else belongs
    to the user.
    """
    if name in previous:
        return True
    return os.path.islink(path)


def remove_legacy_symlinks() -> int:
    """Remove symlinks into the AgentKit source tree, including ones this setup made.

    An earlier version of this setup symlinked each bundle instead of copying it.
    Those links carry the source frontmatter, so a `ck:`-named one is dropped by the
    Harness and duplicates the normalized copy that replaced it. A link pointing
    outside the source tree belongs to the user and stays.
    """
    source_root = os.path.realpath(SOURCE) + os.sep
    removed = 0
    for entry in os.listdir(DEST):
        path = os.path.join(DEST, entry)
        if os.path.islink(path) and os.path.realpath(path).startswith(source_root):
            os.remove(path)
            removed += 1
    return removed


def main() -> int:
    sources = [root for root in [SOURCE, *kit_skill_roots()] if os.path.isdir(root)]
    if not sources:
        print(f"skills: no AgentKit skill source at {SOURCE} or {KIT_CACHE}; nothing mirrored")
        return 0

    os.makedirs(DEST, exist_ok=True)
    previous = previous_names()
    legacy = remove_legacy_symlinks()

    mirrored: dict[str, str] = {}
    weights: dict[str, int] = {}
    shared: list[str] = []
    unusable: list[str] = []

    for root in sources:
        for bundle, directory in find_bundles(root):
            with open(os.path.join(bundle, "SKILL.md"), encoding="utf-8", errors="replace") as handle:
                skill_md = handle.read()
            declared = declared_name(skill_md)
            if declared is None:
                unusable.append(f"{directory} (no frontmatter name)")
                continue
            name = normalize(declared, directory)
            if name is None:
                unusable.append(f"{directory} (unusable name {declared!r})")
                continue
            weight = bundle_weight(bundle)
            if name in mirrored:
                if weight <= weights[name]:
                    shared.append(f"{directory} -> {name} (kept {mirrored[name]})")
                    continue
                shared.append(f"{directory} -> {name} (replaces {mirrored[name]})")
            mirrored[name] = bundle
            weights[name] = weight

    written = 0
    skipped = 0
    for name, bundle in sorted(mirrored.items()):
        target = os.path.join(DEST, name)
        if os.path.exists(target) and not owned(target, name, previous):
            skipped += 1
            continue
        if os.path.islink(target) or os.path.exists(target):
            if os.path.islink(target) or os.path.isfile(target):
                os.remove(target)
            else:
                shutil.rmtree(target)
        shutil.copytree(bundle, target, symlinks=True)
        manifest = os.path.join(target, "SKILL.md")
        with open(manifest, encoding="utf-8", errors="replace") as handle:
            skill_md = handle.read()
        block = FRONTMATTER.match(skill_md)
        if block is None:
            # find_bundles only admits bundles whose SKILL.md has frontmatter.
            raise AssertionError(f"{manifest} lost its frontmatter after copying")
        head = NAME_LINE.sub(f"name: {name}", block.group(1), count=1)
        with open(manifest, "w", encoding="utf-8") as handle:
            handle.write(f"---\n{head}\n---\n{skill_md[block.end():]}")
        written += 1

    pruned = 0
    for name in sorted(previous - set(mirrored)):
        target = os.path.join(DEST, name)
        if os.path.islink(target):
            os.remove(target)
            pruned += 1
        elif os.path.isdir(target):
            shutil.rmtree(target)
            pruned += 1

    with open(MARKER, "w", encoding="utf-8") as handle:
        handle.write("".join(f"{name}\n" for name in sorted(mirrored)))

    print(
        f"skills: {written} mirrored, {skipped} left to you, {pruned} pruned, "
        f"{legacy} legacy link(s) removed -> {DEST}"
    )
    for note in shared:
        print(f"skills: variant chosen: {note}")
    for note in unusable:
        print(f"skills: skipped: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
