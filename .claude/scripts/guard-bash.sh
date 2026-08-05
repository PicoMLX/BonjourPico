#!/usr/bin/env bash
# PreToolUse hook (Bash). Tripwire against dangerous git/gh/test operations.
set -u

if ! command -v python3 >/dev/null 2>&1; then
  echo "BLOCKED: Bash policy hook requires python3 and cannot safely inspect this command." >&2
  exit 2
fi

HOOK_INPUT="$(cat)"
HOOK_INPUT="$HOOK_INPUT" python3 <<'PY'
import json
import os
from pathlib import PurePosixPath
import re
import shlex
import subprocess
import sys

try:
    data = json.loads(os.environ["HOOK_INPUT"])
    command = (data.get("tool_input", {}) or {}).get("command", "") or ""
except (KeyError, json.JSONDecodeError) as error:
    sys.stderr.write(f"BLOCKED: invalid Bash-hook input: {error}\n")
    sys.exit(2)

if not command:
    sys.exit(0)

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars="|&;<>()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
except ValueError as error:
    sys.stderr.write(f"BLOCKED: cannot safely parse Bash command: {error}\n")
    sys.exit(2)

separators = {"|", "||", "&", "&&", ";", "(", ")"}

def command_end(start: int) -> int:
    index = start
    while index < len(tokens) and tokens[index] not in separators:
        index += 1
    return index

def executable(token: str) -> str:
    return PurePosixPath(token).name

def git_subcommand(start: int, end: int):
    takes_value = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"}
    index = start + 1
    while index < end:
        token = tokens[index]
        if token in takes_value:
            index += 2
        elif token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--super-prefix=", "--config-env=")):
            index += 1
        elif token.startswith("-"):
            index += 1
        else:
            return token, index
    return "", end

def git_defines_command_alias(start: int, end: int) -> bool:
    def is_alias_setting(setting: str) -> bool:
        key = setting.split("=", 1)[0].strip().lower()
        return key.startswith("alias.")

    index = start + 1
    while index < end:
        token = tokens[index]
        if token in {"-c", "--config-env"}:
            index += 1
            if index < end and is_alias_setting(tokens[index]):
                return True
        elif token.startswith("-c") and token != "-c":
            if is_alias_setting(token[2:]):
                return True
        elif token.startswith("--config-env="):
            if is_alias_setting(token[len("--config-env="):]):
                return True
        index += 1
    return False

def protected_ref(argument: str) -> bool:
    ref = argument.lstrip("+")
    if ":" in ref:
        ref = ref.rsplit(":", 1)[1]
    if ref.startswith("refs/heads/"):
        ref = ref[len("refs/heads/"):]
    return ref in {"main", "master"}

def push_refspecs(arguments: list[str]) -> list[str]:
    takes_value = {"--receive-pack", "--exec", "-o", "--push-option"}
    repository_from_option = False
    positionals = []
    index = 0
    positional_only = False
    while index < len(arguments):
        token = arguments[index]
        if positional_only:
            positionals.append(token)
            index += 1
        elif token == "--":
            positional_only = True
            index += 1
        elif token == "--repo":
            repository_from_option = True
            index += 2
        elif token.startswith("--repo="):
            repository_from_option = True
            index += 1
        elif token in takes_value:
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            positionals.append(token)
            index += 1
    return positionals if repository_from_option else positionals[1:]

def git_output(prefix: list[str], *arguments: str) -> str:
    try:
        result = subprocess.run(
            [*prefix, *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""

def protected_tracking_ref(reference: str) -> bool:
    ref = reference.strip()
    if ref.startswith("refs/remotes/"):
        ref = ref[len("refs/remotes/"):]
        ref = ref.split("/", 1)[1] if "/" in ref else ref
    elif ref.startswith("refs/heads/"):
        ref = ref[len("refs/heads/"):]
    elif "/" in ref:
        ref = ref.split("/", 1)[1]
    return ref in {"main", "master"}

def implicit_push_targets_protected(prefix: list[str]) -> bool:
    branch = git_output(prefix, "symbolic-ref", "--quiet", "--short", "HEAD")
    if protected_ref(branch):
        return True
    return any(
        protected_tracking_ref(git_output(prefix, "rev-parse", "--abbrev-ref", "--symbolic-full-name", selector))
        for selector in ("@{push}", "@{upstream}")
    )

def test_path(argument: str) -> bool:
    if argument.startswith("-"):
        return False
    # Interpreter command strings can embed paths inside Path("...") or
    # similar calls. Split shell/Python punctuation so those paths are still
    # inspected without treating every word as a path.
    fragments = re.split(r"[\s'\"`(){}:,;=]+", argument.replace("\\", "/"))
    for fragment in fragments:
        normalized = fragment.rstrip("/")
        if not normalized:
            continue
        raw_parts = [part.strip("*?[]") for part in PurePosixPath(normalized).parts]
        parts = [part.lower() for part in raw_parts]
        if any(part in {"test", "tests", "__tests__"} for part in parts):
            return True
        # Swift/Xcode convention: FooTests is a test bundle directory. Keep
        # this case-sensitive so an unrelated directory such as "contests"
        # is not classified as a test tree.
        if any(part.endswith("Tests") for part in raw_parts):
            return True
        name = parts[-1] if parts else ""
        if (
            name.startswith("test_")
            or name.endswith(("_test.py", "_tests.py", "_test.go", "_tests.go"))
            or re.search(r"\.(test|spec)\.[jt]sx?$", name, re.IGNORECASE)
            or (name.endswith(".swift") and (name.startswith("test") or name.endswith("tests.swift")))
        ):
            return True
    return False

policy_path = re.compile(
    r"(^|[^A-Za-z0-9_.-])(?:"
    r"\.(?:claude|codex|agents)(?=/|$|[^A-Za-z0-9_.-])"
    r"|\.github/workflows(?=/|$|[^A-Za-z0-9_.-])"
    r"|AGENTS\.md(?=$|[^A-Za-z0-9_.-]))"
)

def protected_policy_path(value: str) -> bool:
    return bool(policy_path.search(value.replace("\\", "/")))

def find_exec_can_write(arguments: list[str]) -> bool:
    actions = {"-exec", "-execdir", "-ok", "-okdir"}
    mutators = {
        "cp", "mv", "install", "touch", "mkdir", "rmdir", "rm", "unlink",
        "truncate", "chmod", "chown", "chgrp", "ln", "tee", "patch", "ed",
        "ex", "dd", "sed", "git", "find", "bash", "dash", "ksh", "sh",
        "zsh", "node", "ruby", "perl", "php", "awk", "gawk", "mawk",
        "env", "command", "sudo", "nice", "xargs",
    }
    for index, argument in enumerate(arguments[:-1]):
        if argument not in actions:
            continue
        action = executable(arguments[index + 1])
        if action.startswith("python") or action in mutators:
            return True
    return False

def redirects_to_policy() -> bool:
    for index, token in enumerate(tokens[:-1]):
        if ">" in token and all(character in "<>&|" for character in token):
            if protected_policy_path(tokens[index + 1]):
                return True
    return False

def redirects_to_tests() -> bool:
    for index, token in enumerate(tokens[:-1]):
        if ">" in token and all(character in "<>&|" for character in token):
            if test_path(tokens[index + 1]):
                return True
    return False

def command_writes_policy(name: str, start: int, end: int) -> bool:
    arguments = tokens[start + 1:end]
    if not any(protected_policy_path(argument) for argument in arguments):
        return False
    if name in {
        "cp", "mv", "install", "touch", "mkdir", "rmdir", "rm", "truncate",
        "chmod", "chown", "chgrp", "ln", "tee", "patch", "ed", "ex", "dd",
    }:
        return True
    if name.startswith("python") or name in {"node", "ruby", "perl", "php", "awk", "gawk", "mawk"}:
        return True
    if name == "sed":
        return any(
            argument == "-i" or argument.startswith("-i")
            or argument == "--in-place" or argument.startswith("--in-place=")
            for argument in arguments
        )
    if name == "find":
        return "-delete" in arguments or find_exec_can_write(arguments)
    if name == "git":
        subcommand, _ = git_subcommand(start, end)
        return subcommand in {"add", "checkout", "restore", "rm", "mv", "clean", "reset"}
    return False

def command_writes_tests(name: str, start: int, end: int) -> bool:
    arguments = tokens[start + 1:end]
    if not any(test_path(argument) for argument in arguments):
        return False
    if name in {
        "cp", "mv", "install", "touch", "mkdir", "rmdir", "rm", "truncate",
        "chmod", "chown", "chgrp", "ln", "tee", "patch", "ed", "ex", "dd",
    }:
        return True
    if name.startswith("python") or name in {"node", "ruby", "perl", "php", "awk", "gawk", "mawk"}:
        return True
    if name == "sed":
        return any(
            argument == "-i" or argument.startswith("-i")
            or argument == "--in-place" or argument.startswith("--in-place=")
            for argument in arguments
        )
    if name == "find":
        return "-delete" in arguments or find_exec_can_write(arguments)
    if name == "git":
        subcommand, _ = git_subcommand(start, end)
        return subcommand in {"checkout", "restore", "rm", "mv", "clean", "reset"}
    return False

def positional_arguments(start: int, end: int, takes_value: set[str]) -> list[str]:
    values = []
    index = start
    while index < end:
        token = tokens[index]
        if token in takes_value:
            index += 2
        elif token.startswith("-"):
            index += 1
        else:
            values.append(token)
            index += 1
    return values

def references_git_alias(argument: str) -> bool:
    return bool(re.search(r"(^|[^A-Za-z0-9_-])alias\.", argument, re.IGNORECASE))

def git_config_writes_alias(arguments: list[str]) -> bool:
    if not any(references_git_alias(argument) for argument in arguments):
        return False
    write_modes = {
        "--add", "--replace-all", "--unset", "--unset-all", "--rename-section",
        "--remove-section", "set", "unset", "rename-section", "remove-section",
    }
    if any(argument in write_modes for argument in arguments):
        return True
    takes_value = {"-f", "--file", "--blob", "--type", "--comment", "--default"}
    positionals = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in takes_value:
            index += 2
        elif argument.startswith("-"):
            index += 1
        else:
            positionals.append(argument)
            index += 1
    read_verbs = {"get", "get-all", "get-regexp", "get-urlmatch", "list"}
    if positionals and positionals[0] in read_verbs:
        return False
    alias_positions = [
        index for index, argument in enumerate(positionals)
        if references_git_alias(argument)
    ]
    return any(index + 1 < len(positionals) for index in alias_positions)

def git_alias_defined(prefix: list[str], subcommand: str) -> bool:
    if not subcommand:
        return False
    return bool(git_output(prefix, "config", "--get", f"alias.{subcommand}"))

def gh_subcommand(start: int, end: int):
    takes_value = {"-R", "--repo", "--hostname", "--config"}
    index = start + 1
    while index < end:
        token = tokens[index]
        if token in takes_value:
            index += 2
        elif token.startswith(("--repo=", "--hostname=", "--config=")):
            index += 1
        elif token.startswith("-"):
            index += 1
        else:
            return token, index
    return "", end

def graphql_query_uses_shell_expansion(source: str) -> bool:
    """Return true when a query= shell word contains an expandable dollar."""
    query_prefixes = (
        "query=", "-fquery=", "-Fquery=", "--raw-field=query=", "--field=query=",
    )
    words = []
    word = []
    word_expands = False
    quote = ""
    escaped = False
    for character in source:
        if escaped:
            word.append(character)
            escaped = False
            continue
        if character == "\\" and quote != "'":
            escaped = True
            continue
        if character == "'" and quote != '"':
            quote = "" if quote == "'" else "'"
            continue
        if character == '"' and quote != "'":
            quote = "" if quote == '"' else '"'
            continue
        if not quote and (character.isspace() or character in "|&;()"):
            if word:
                words.append(("".join(word), word_expands))
                word = []
                word_expands = False
            continue
        word.append(character)
        if character == "$" and quote != "'":
            word_expands = True
    if word:
        words.append(("".join(word), word_expands))
    return any(
        expands and any(value.startswith(prefix) for prefix in query_prefixes)
        for value, expands in words
    )

def gh_api_is_mutating(arguments: list[str], source: str) -> bool:
    method = ""
    endpoint = ""
    fields = []
    has_input = False
    index = 0
    while index < len(arguments):
        token = arguments[index]
        if token in {"-X", "--method"}:
            method = arguments[index + 1] if index + 1 < len(arguments) else ""
            index += 2
        elif token.startswith("--method="):
            method = token.split("=", 1)[1]
            index += 1
        elif token.startswith("-X") and token != "-X":
            method = token[2:]
            index += 1
        elif token in {"-f", "--raw-field", "-F", "--field"}:
            if index + 1 < len(arguments):
                fields.append(arguments[index + 1])
            index += 2
        elif token.startswith(("--raw-field=", "--field=")):
            fields.append(token.split("=", 1)[1])
            index += 1
        elif (token.startswith("-f") or token.startswith("-F")) and token not in {"-f", "-F"}:
            fields.append(token[2:])
            index += 1
        elif token == "--input" or token.startswith("--input="):
            has_input = True
            index += 2 if token == "--input" else 1
        elif token in {"-H", "--header", "--hostname", "--cache", "--jq", "--template", "--preview"}:
            index += 2
        elif token.startswith(("--header=", "--hostname=", "--cache=", "--jq=", "--template=", "--preview=")):
            index += 1
        elif token == "--":
            index += 1
        elif token.startswith("-"):
            index += 1
        elif not endpoint:
            endpoint = token
            index += 1
        else:
            index += 1

    effective_method = (method or ("POST" if fields or has_input else "GET")).upper()
    if effective_method in {"GET", "HEAD"}:
        return False

    if endpoint == "graphql":
        queries = [field.split("=", 1)[1] for field in fields if field.startswith("query=")]
        if (
            not queries
            or any(query.startswith("@") for query in queries)
            or graphql_query_uses_shell_expansion(source)
        ):
            return True
        return any(re.search(r"\bmutation\b", query, re.IGNORECASE) for query in queries)

    reaction_endpoint = re.fullmatch(
        r"repos/[^/]+/[^/]+/(?:issues|pulls)/(?:comments/)?[^/]+/reactions",
        endpoint,
    )
    if reaction_endpoint and effective_method == "POST" and not has_input:
        return fields != ["content=+1"]
    return True

def push_uses_force(arguments: list[str]) -> bool:
    for argument in arguments:
        if argument == "--":
            break
        if argument == "--force" or argument.startswith("--force-with-lease"):
            return True
        if not argument.startswith("-") or argument.startswith("--"):
            continue
        for option in argument[1:]:
            if option == "f":
                return True
            if option == "o":
                break  # The remainder is --push-option's value, not a flag cluster.
    return False

def shell_uses_command_string(arguments: list[str]) -> bool:
    for argument in arguments:
        if argument == "--":
            break
        if argument == "-c":
            return True
        if argument.startswith("-") and not argument.startswith("--") and "c" in argument[1:]:
            return True
    return False

def git_apply_is_read_only(arguments: list[str]) -> bool:
    reporting = {"--check", "--stat", "--numstat", "--summary"}
    return "--apply" not in arguments and any(argument in reporting for argument in arguments)

def git_apply_patch_files(arguments: list[str]) -> list[str]:
    takes_value = {
        "-p", "-C", "--directory", "--exclude", "--include",
        "--whitespace", "--build-fake-ancestor",
    }
    patch_files = []
    index = 0
    positional_only = False
    while index < len(arguments):
        argument = arguments[index]
        if positional_only:
            patch_files.append(argument)
            index += 1
        elif argument == "--":
            positional_only = True
            index += 1
        elif argument in takes_value:
            index += 2
        elif argument.startswith(("--directory=", "--exclude=", "--include=", "--whitespace=", "--build-fake-ancestor=")):
            index += 1
        elif re.fullmatch(r"-[pC]\d+", argument):
            index += 1
        elif argument.startswith("-"):
            index += 1
        else:
            patch_files.append(argument)
            index += 1
    return patch_files

def git_apply_directories(arguments: list[str]) -> list[str]:
    directories = []
    for index, argument in enumerate(arguments):
        if argument == "--directory" and index + 1 < len(arguments):
            directories.append(arguments[index + 1])
        elif argument.startswith("--directory="):
            directories.append(argument.split("=", 1)[1])
    return directories

def git_patch_targets(source: str) -> list[str]:
    targets = []
    for line in source.splitlines():
        candidates = []
        if line.startswith("diff --git "):
            try:
                candidates = shlex.split(line)[2:4]
            except ValueError:
                return []
        elif line.startswith(("--- ", "+++ ", "rename from ", "rename to ")):
            prefix = next(prefix for prefix in ("--- ", "+++ ", "rename from ", "rename to ") if line.startswith(prefix))
            try:
                values = shlex.split(line[len(prefix):])
            except ValueError:
                return []
            candidates = values[:1]
        for candidate in candidates:
            if candidate == "/dev/null":
                continue
            normalized = candidate.replace("\\", "/")
            if normalized.startswith(("a/", "b/")):
                normalized = normalized[2:]
            targets.append(normalized)
    return targets

def git_apply_block_reason(arguments: list[str], prefix: list[str]) -> str:
    directories = git_apply_directories(arguments)
    git_context = "/".join(
        prefix[index + 1]
        for index, argument in enumerate(prefix[:-1])
        if argument == "-C"
    )
    destination_prefix = "/".join([git_context, *directories]).strip("/")
    if destination_prefix and (
        test_path(destination_prefix) or protected_policy_path(destination_prefix)
    ):
        return "applying patch to protected files"
    patch_files = git_apply_patch_files(arguments)
    if not patch_files:
        return "uninspectable git apply"
    for patch_file in patch_files:
        try:
            source = open(patch_file, encoding="utf-8").read()
        except (OSError, UnicodeError):
            return "uninspectable git apply"
        targets = git_patch_targets(source)
        if not targets:
            return "uninspectable git apply"
        destinations = [f"{destination_prefix}/{path}".strip("/") for path in targets]
        if any(test_path(path) or protected_policy_path(path) for path in destinations):
            return "applying patch to protected files"
    return ""

def has_active_dynamic_evaluation(source: str) -> bool:
    """Detect shell constructs that can execute commands hidden from shlex."""
    quote = ""
    escaped = False
    for index, character in enumerate(source):
        if quote == "'":
            if character == "'":
                quote = ""
            continue
        if escaped:
            escaped = False
            continue
        if character == "\\":
            escaped = True
            continue
        if character == "'" and not quote:
            quote = "'"
            continue
        if character == '"':
            quote = "" if quote == '"' else '"'
            continue
        if character == "`":
            return True
        if character == "$" and source[index + 1:index + 2] == "(":
            if source[index + 2:index + 3] != "(":
                return True
        if not quote and character in "<>" and source[index + 1:index + 2] == "(":
            return True
    return False

def block(label: str):
    sys.stderr.write(
        f"BLOCKED ({label}): {command.strip()[:200]}\n"
        "Repository loop policy reserves this operation for a human.\n"
    )
    sys.exit(2)

if has_active_dynamic_evaluation(command):
    block("dynamic shell evaluation")
if redirects_to_policy():
    block("writing policy/CI files through Bash")
if redirects_to_tests():
    block("writing test files through Bash")

for index, token in enumerate(tokens):
    name = executable(token)
    end = command_end(index + 1)
    if command_writes_policy(name, index, end):
        block("writing policy/CI files through Bash")
    if command_writes_tests(name, index, end):
        block("writing test files through Bash")
    if name == "eval":
        block("dynamic shell evaluation")
    elif name == "git":
        subcommand, sub_index = git_subcommand(index, end)
        if git_defines_command_alias(index, sub_index):
            block("command-local Git alias")
        arguments = tokens[sub_index + 1:end]
        if subcommand == "config" and git_config_writes_alias(arguments):
            block("persisted Git alias")
        if git_alias_defined(tokens[index:sub_index], subcommand):
            block("Git alias command")
        if subcommand == "push":
            if push_uses_force(arguments):
                block("force push")
            if any(arg in {"--all", "--branches", "--mirror"} for arg in arguments):
                block("push to main")
            refspecs = push_refspecs(arguments)
            if any(protected_ref(arg) for arg in refspecs):
                block("push to main")
            needs_branch_context = (
                (not refspecs and "--tags" not in arguments)
                or any(arg.lstrip("+") in {"HEAD", "@"} for arg in refspecs)
            )
            if needs_branch_context and implicit_push_targets_protected(tokens[index:sub_index]):
                block("push to main")
        elif subcommand == "reset" and "--hard" in arguments:
            block("hard reset")
        elif subcommand == "clean" and any(arg.startswith("-") and ("f" in arg or "d" in arg) for arg in arguments):
            block("git clean -f/-d")
        elif subcommand == "rm" and any(test_path(arg) for arg in arguments):
            block("deleting test files")
        elif subcommand == "apply" and not git_apply_is_read_only(arguments):
            reason = git_apply_block_reason(arguments, tokens[index:sub_index])
            if reason:
                block(reason)
    elif name == "gh":
        subcommand, subcommand_index = gh_subcommand(index, end)
        if subcommand == "api" and gh_api_is_mutating(tokens[subcommand_index + 1:end], command):
            block("mutating gh api")
        words = positional_arguments(
            index + 1,
            end,
            {"-R", "--repo", "--hostname", "--config", "--jq", "--template"},
        )
        if len(words) >= 2 and words[0:2] == ["pr", "merge"]:
            block("PR merge (human-only)")
    elif name == "rm" and any(test_path(arg) for arg in tokens[index + 1:end]):
        block("deleting test files")
    elif name in {"bash", "dash", "ksh", "sh", "zsh"} and shell_uses_command_string(tokens[index + 1:end]):
        block("nested shell command")

sys.exit(0)
PY
status=$?
if [[ $status -ne 0 ]]; then
  if [[ $status -ne 2 ]]; then
    echo "BLOCKED: Bash policy hook failed unexpectedly; refusing to fail open." >&2
  fi
  exit 2
fi
