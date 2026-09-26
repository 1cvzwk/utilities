import ast
import gc
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
import gradio as gr
import matplotlib.pyplot as plt
import numpy as np
import requests
from ddgs import DDGS
import io
from PIL import Image

# -----------------------------------------------------------------------------
# CONFIGURATION & INITIAL STATE FACTORY
# -----------------------------------------------------------------------------
KOBOLD_ENDPOINT = "http://localhost:5001/v1/chat/completions"
MAX_OUTPUT_TOKENS = 3096
MAX_CONTEXT_HISTORY_TURNS = 6
MAX_SESSIONS = 10
BACKUP_DIR = "./session_backups"

os.makedirs(BACKUP_DIR, exist_ok=True)

CHAT_PURPOSES = {
    "general purpose": (
        "General Purpose Mode: Follow the established conversation history target without changing focus. "
        "Maintain the ongoing vibe (e.g., coding, conceptual analysis) until explicitly interjected by the user. "
        "Provide direct, complete, and balanced outputs."
    ),
    "coding": (
        "Coding Mode: OUTPUT ONLY CODE and minimal explanations. "
        "Focus on bug fixing, optimizing, debugging, and adding helper functions to the codebase. "
        "STRICT RULE: Do NOT change the core structure, main architectural purpose, or primary goal of the script."
    ),
    "news": (
        "News Mode: Focus strictly on real-time news data from extracted web sources. "
        "Continuously deliver fresh, newly released breaking developments on the target topic. "
        "STRICT RULE: Keep the central topic strictly unchanged (e.g., Bitcoin news stays strictly on Bitcoin news)."
    ),
    "informative": (
        "Informative Mode: Expand on the core topic by layering deeper data, exact specifications, and analytical breakdowns. "
        "STRICT RULE: Do NOT drift off-topic; incrementally add deep insights, technical metrics, and empirical data."
    ),
    "theory": (
        "Theory Mode: Navigate within the theoretical framework, mathematical proofs, and scientific principles of the topic. "
        "STRICT RULE: Explore adjacent existential, mathematical, or scientific implications while remaining tightly anchored to the target theory."
    )
}

def create_default_execution_state():
    return {
        "status": "STOPPED",
        "topic": "",
        "context": "",
        "initial_prompt": "",
        "custom_notes": "",
        "chat_purpose": "general purpose",
        "history_memory": [],
        "compressed_summary": "",
        "iterations_count": 0,
        "total_tokens_generated": 0,
        "start_time": None,
        "auto_pilot": True,
        "latest_valid_lambda": None,
        "coherence_pct": 90,
        "enable_veracity_check": True,
        "last_extracted_web_data": "No web search executed yet.",
        "last_veracity_score": 100,
        "auto_injection_enabled": True,
    }

# -----------------------------------------------------------------------------
# AUTOMATED VENV ENVIRONMENT CREATION & HEALING DEBUG ENGINE
# -----------------------------------------------------------------------------
def extract_codebox_from_chat_output(text: str) -> str:
    """Return the last fenced Python code block from a completed model response."""
    matches = re.findall(
        r"```(?:python|py|python3)?\s*\n?(.*?)```",
        text or "",
        flags=re.IGNORECASE | re.DOTALL,
    )
    return matches[-1].strip() if matches else ""


def debug_and_run_current_code(script_code: str, venv_dir: str = ".venv_debug") -> dict:
    """Execute only the current implementation and return raw evidence."""
    root_dir = os.path.abspath(os.getcwd())
    venv_path = os.path.join(root_dir, venv_dir)
    venv_python = os.path.join(venv_path, "Scripts", "python.exe")
    test_script_path = os.path.join(root_dir, "_temp_debug_target.py")

    try:
        if not os.path.exists(venv_python):
            print(f"[*] Creating Virtual Environment: {venv_path}")
            subprocess.run([sys.executable, "-m", "venv", venv_path], check=True)

        with open(test_script_path, "w", encoding="utf-8") as f:
            f.write(script_code)

        ps_command = (
            f"Set-Location -LiteralPath '{root_dir}'; "
            f"& '{venv_python}' '{test_script_path}'"
        )
        process = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_command],
            cwd=root_dir,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

        stdout = process.stdout.strip()
        stderr = process.stderr.strip()
        combined = f"{stdout}\n{stderr}"
        warning_or_error = bool(re.search(
            r"(?im)\b(?:warning|warn|error|exception|traceback|failed|failure)\b",
            combined,
        ))

        return {
            "returncode": process.returncode,
            "stdout": stdout,
            "stderr": stderr,
            "working_signal": process.returncode == 0 and not stderr and not warning_or_error,
        }
    except Exception as exc:
        return {
            "returncode": -1,
            "stdout": "",
            "stderr": f"{type(exc).__name__}: {exc}",
            "working_signal": False,
        }
    finally:
        if os.path.exists(test_script_path):
            try:
                os.remove(test_script_path)
            except OSError:
                pass


def request_model_code_repair(topic: str, directive: str, current_code: str, result: dict, state: dict) -> str:
    """Ask Kobold to rewrite the current implementation without changing its goal/structure."""
    repair_prompt = f"""
CODING REPAIR DIRECTIVE.

The current implementation belongs to an active task. Repair it and return a NEW
complete executable Python implementation in ONE fenced ```python``` code block.

LOCKED OBJECTIVE:
{topic}

LOCKED DIRECTIVE:
{directive}

PRESERVE:
- the original focus and goal
- the existing architectural structure
- existing working functionality
- interfaces and intended behavior

ALLOW:
- rewriting broken code
- replacing a broken implementation
- correcting syntax/runtime/logic errors
- correcting dependencies/imports
- improving robustness and execution reliability
- improving performance when it does not change the purpose

DO NOT:
- abandon the task
- change the objective
- switch to an unrelated solution
- merely explain the error
- return a partial patch when a complete executable replacement is needed

CURRENT CODE:
```python
{current_code}
```

POWERSHELL EXECUTION RESULT:
Exit code: {result.get('returncode')}
STDOUT:
{result.get('stdout', '')}

STDERR:
{result.get('stderr', '')}

Rewrite the complete current implementation now. Output the corrected codebox first.
""".strip()

    payload = {
        "messages": [
            {"role": "system", "content": "You are the coding repair engine. Preserve goal and structure. Return a complete Python codebox."},
            {"role": "user", "content": repair_prompt},
        ],
        "temperature": 0.05,
        "top_p": 0.9,
        "max_tokens": MAX_OUTPUT_TOKENS,
        "stream": False,
    }

    try:
        res = requests.post(KOBOLD_ENDPOINT, json=payload, timeout=120)
        res.raise_for_status()
        raw = res.json()["choices"][0]["message"]["content"].strip()
        return raw
    except Exception as exc:
        print(f"[REPAIR MODEL ERROR] {type(exc).__name__}: {exc}")
        return ""


def execute_coding_cycle(bot_response: str, topic: str, directive: str, state: dict, max_repair_cycles: int = 12) -> dict:
    """Keep one directive active until its implementation earns a clean working signal."""
    current_response = bot_response

    for cycle in range(1, max_repair_cycles + 1):
        code = extract_codebox_from_chat_output(current_response)
        if not code:
            return {"approved": False, "response": current_response, "reason": "No Python codebox found."}

        print("\n" + "=" * 90)
        print(f"CODING EXECUTION CYCLE {cycle}/{max_repair_cycles}")
        print("=" * 90)
        print(code)
        print("=" * 90)

        result = debug_and_run_current_code(code)
        if result["stdout"]:
            print("--- POWERSHELL STDOUT ---")
            print(result["stdout"])
        if result["stderr"]:
            print("--- POWERSHELL STDERR / WARNINGS ---")
            print(result["stderr"])

        if result["working_signal"]:
            print("\n[WORKING SIGNAL] APPROVED — current directive is complete.")
            return {"approved": True, "response": current_response, "code": code, "result": result, "cycles": cycle}

        print("\n[WORKING SIGNAL] NOT APPROVED — leaving this result alone and starting a NEW repair execution.")
        repaired_response = request_model_code_repair(topic, directive, code, result, state)
        if not repaired_response:
            return {"approved": False, "response": current_response, "reason": "Repair model returned no implementation."}

        current_response = repaired_response

    return {
        "approved": False,
        "response": current_response,
        "reason": f"Maximum repair cycles ({max_repair_cycles}) reached.",
    }


def debug_and_auto_fix_in_venv(script_code: str, venv_dir: str = ".venv_debug", max_retries: int = 12) -> bool:
    """Compatibility wrapper: repeatedly execute/repair the current code until approved."""
    result = execute_coding_cycle(script_code, "current coding task", "repair current implementation", {}, max_retries)
    return bool(result.get("approved"))

# -----------------------------------------------------------------------------
# GLOBAL STATE PERSISTENCE & BACKUP / RESTORE SYSTEM
# -----------------------------------------------------------------------------
class StateEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, (datetime, np.datetime64)):
            return obj.isoformat()
        if isinstance(obj, (np.integer, np.floating)):
            return obj.item()
        if isinstance(obj, np.ndarray):
            return obj.tolist()
        return super().default(obj)

def save_system_snapshot(all_states: list[dict], all_histories: list[list], filename: str = None) -> str:
    if not filename:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = os.path.join(BACKUP_DIR, f"system_snapshot_{timestamp}.json")

    backup_payload = {
        "metadata": {
            "version": "1.3",
            "timestamp": datetime.now().isoformat(),
            "session_count": len(all_states),
        },
        "sessions": [],
    }

    for idx, (state, history) in enumerate(zip(all_states, all_histories), 1):
        backup_payload["sessions"].append({
            "session_id": idx,
            "execution_state": state,
            "chat_history": history,
        })

    with open(filename, "w", encoding="utf-8") as f:
        json.dump(backup_payload, f, indent=2, cls=StateEncoder)
    return filename

def load_system_snapshot(filepath: str) -> tuple[list[dict], list[list]]:
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"Backup file not found at: {filepath}")

    with open(filepath, "r", encoding="utf-8") as f:
        backup_payload = json.load(f)

    loaded_states, loaded_histories = [], []
    for s_data in backup_payload.get("sessions", []):
        loaded_states.append(s_data.get("execution_state", create_default_execution_state()))
        loaded_histories.append(s_data.get("chat_history", []))

    while len(loaded_states) < MAX_SESSIONS:
        loaded_states.append(create_default_execution_state())
        loaded_histories.append([])

    return loaded_states, loaded_histories

def panic_emergency_backup(*args) -> str:
    states = list(args[:MAX_SESSIONS])
    histories = list(args[MAX_SESSIONS : MAX_SESSIONS * 2])
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    panic_filename = os.path.join(BACKUP_DIR, f"panic_backup_{timestamp}.json")

    try:
        saved_file = save_system_snapshot(states, histories, filename=panic_filename)
        return (
            f"🚨 **EMERGENCY PANIC BACKUP SUCCESSFUL!**\n\n"
            f"• **Saved To:** `{os.path.abspath(saved_file)}`\n"
            f"• **Timestamp:** `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`\n"
            f"• **Active Sessions Backed Up:** `{len(states)}`"
        )
    except Exception as e:
        return f"❌ **PANIC BACKUP FAILED:** {str(e)}"

# -----------------------------------------------------------------------------
# UTILITIES: LAMBDAS, PLOTS, DUCKDUCKGO, AND VERACITY CHECKER
# -----------------------------------------------------------------------------
def extract_and_test_lambdas(text: str) -> list[dict]:
    matches = re.findall(r"(lambda\s+[\w\s,]+:\s*[^`\n]+)", text)
    evaluated_results = []
    safe_globals = {
        "np": np, "sin": np.sin, "cos": np.cos, "tan": np.tan,
        "exp": np.exp, "sqrt": np.sqrt, "pi": np.pi, "log": np.log, "sinc": np.sinc,
    }

    for expr in set(matches):
        try:
            parsed = ast.parse(expr, mode="eval")
            compiled = compile(parsed, filename="<string>", mode="eval")
            fn = eval(compiled, safe_globals)
            test_x = np.linspace(-5, 5, 100)
            test_y = fn(test_x)

            if isinstance(test_y, (np.ndarray, int, float, list)):
                evaluated_results.append({
                    "expr": expr, "fn": fn, "status": "VALID", "sample_eval": float(np.mean(test_y)),
                })
        except Exception as e:
            evaluated_results.append({"expr": expr, "fn": None, "status": f"INVALID ({str(e)})"})

    return evaluated_results

def plot_lambda_function(fn, expr_str: str):
    try:
        x = np.linspace(-10, 10, 400)
        y = fn(x)
        fig, ax = plt.subplots(figsize=(5, 3), dpi=80)
        ax.plot(x, y, color="#1f77b4", linewidth=2, label=f"`{expr_str}`")
        ax.axhline(0, color="gray", linestyle="--", linewidth=0.8)
        ax.axvline(0, color="gray", linestyle="--", linewidth=0.8)
        ax.grid(True, linestyle=":", alpha=0.6)
        ax.set_title("Dynamic Function Evaluation", fontsize=10)
        ax.set_xlabel("x")
        ax.set_ylabel("f(x)")
        ax.legend(loc="upper right", fontsize=8)
        plt.tight_layout()

        buf = io.BytesIO()
        plt.savefig(buf, format="png", bbox_inches="tight")
        buf.seek(0)
        img = Image.open(buf)
        plt.close(fig)
        return img
    except Exception:
        plt.close("all")
        return None

def search_duckduckgo_raw(query: str) -> tuple[str, str]:
    if not query.strip():
        return "No active query provided.", "No query entered for web search."

    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=4))
            if not results:
                return "No web results found.", "No web search data extracted for this topic."

            llm_context = "\n=== REAL-TIME WEB CONTEXT ===\n"
            raw_extracted = f"### 🌐 Extracted Web Content for Query: '{query}'\n\n"

            for i, r in enumerate(results, 1):
                title, body, href = r.get("title", "Untitled"), r.get("body", "No content"), r.get("href", "#")
                llm_context += f"[{i}] {title}: {body}\n"
                raw_extracted += f"#### [{i}] [{title}]({href})\n{body}\n\n---\n\n"

            llm_context += "=== END CONTEXT ===\n"
            return llm_context, raw_extracted
    except Exception as e:
        err_msg = f"Web search failed: {str(e)}"
        return err_msg, err_msg

def evaluate_veracity_and_reality(generated_text: str, source_context: str, coherence_val: int) -> int:
    verifier_prompt = (
        "You are an impartial Veracity Evaluator. Evaluate the following generated content for factual accuracy.\n\n"
        f'Reference Context:\n"""{source_context[:1500]}"""\n\n'
        f'Generated Content To Verify:\n"""{generated_text[:2000]}"""\n\n'
        'Return ONLY a valid JSON object with format: {"veracity_score": <number between 0 and 100>, "reason": "<brief reason>"}'
    )

    payload = {
        "messages": [
            {"role": "system", "content": "You output JSON only."},
            {"role": "user", "content": verifier_prompt},
        ],
        "temperature": 0.1,
        "max_tokens": 128,
    }

    try:
        res = requests.post(KOBOLD_ENDPOINT, json=payload, timeout=20)
        raw_text = res.json()["choices"][0]["message"]["content"].strip()
        json_match = re.search(r"\{.*\}", raw_text, re.DOTALL)
        if json_match:
            data = json.loads(json_match.group(0))
            score = int(data.get("veracity_score", 95))
            return max(0, min(100, score))
    except Exception:
        pass

    return max(70, min(100, int(coherence_val * 0.95)))

# -----------------------------------------------------------------------------
# QUANTIZING AUTONOMOUS DIRECTIVE ENGINE & INJECTION EXTENSIONS
# -----------------------------------------------------------------------------
def inject_auto_interjection(last_text: str, state: dict) -> str:
    purpose = state.get("chat_purpose", "general purpose")
    topic = state.get("topic", "active analysis")
    return (
        f"\n\n[AUTOMATIC QUANTIZED CONTINUATION INJECTION]\n"
        f"Mode: {purpose.upper()} | Context Target: '{topic}'\n"
        f"Directive: Output reached sequence conclusion. Expand directly upon the above structure "
        f"with high precision, completing open derivations, code implementations, or technical findings."
    )

def quantize_and_compress_history(state: dict) -> str:
    memory = state.get("history_memory", [])
    if len(memory) <= MAX_CONTEXT_HISTORY_TURNS:
        return state.get("compressed_summary", "")

    summary_content = " ".join([m.get("content", "")[:100] for m in memory[:-MAX_CONTEXT_HISTORY_TURNS]])
    quantized_summary = f"Quantized Abstract: {summary_content[:500]}..."
    state["compressed_summary"] = quantized_summary
    return quantized_summary

def generate_next_research_directive(last_output: str, current_topic: str, state: dict) -> tuple[str, str]:
    chat_purpose = state.get("chat_purpose", "general purpose")
    initial_prompt = state.get("initial_prompt", current_topic)

    purpose_constraints = {
        "coding": (
            "QUANTIZATION RULE: Maintain the initial code's main purpose and architecture strictly. "
            "Formulate the next directive to debug, optimize performance, handle edge cases, or "
            "add brand new utility functions WITHOUT altering the fundamental goal or program structure."
        ),
        "news": f"QUANTIZATION RULE: Keep focus strictly locked onto '{initial_prompt}'. Seek brand-new, freshly updated news.",
        "informative": f"QUANTIZATION RULE: Do not change subject from '{initial_prompt}'. Add deeper analytical data.",
        "theory": f"QUANTIZATION RULE: Remain strictly inside theoretical domain of '{initial_prompt}'. Navigate adjacent proofs.",
        "general purpose": "QUANTIZATION RULE: Follow the user's primary goal and conversational vibe.",
    }

    constraint_str = purpose_constraints.get(chat_purpose, purpose_constraints["general purpose"])

    reflector_prompt = (
        f"Initial Target Focus: '{initial_prompt}'\n"
        f"Active Mode: '{chat_purpose.upper()}'\n"
        f"Current Topic: '{current_topic}'\n"
        f"Latest Output Content:\n\"\"\"{last_output[:1000]}\"\"\"\n\n"
        f"DIRECTIVE QUANTIZATION CONSTRAINTS:\n{constraint_str}\n\n"
        "Generate a NEW research directive JSON object matching this strict guidance:\n"
        '{"next_topic": "Topic or Query", "next_directive": "Specific task instruction"}'
    )

    payload = {
        "messages": [
            {"role": "system", "content": "You output JSON only."},
            {"role": "user", "content": reflector_prompt},
        ],
        "temperature": 0.2,
        "max_tokens": 256,
    }

    try:
        res = requests.post(KOBOLD_ENDPOINT, json=payload, timeout=20)
        raw_text = res.json()["choices"][0]["message"]["content"].strip()
        json_match = re.search(r"\{.*\}", raw_text, re.DOTALL)
        if json_match:
            data = json.loads(json_match.group(0))
            return data.get("next_topic", current_topic), data.get("next_directive", "Deepen domain analysis while keeping core scope.")
    except Exception:
        pass

    return f"{initial_prompt} (Phase {state['iterations_count'] + 1})", "Increment scope and perform deep execution."

def estimate_tokens(text: str) -> int:
    return len(text.split()) * 4 // 3

def render_metrics(state: dict) -> str:
    status = state["status"]
    passes = state["iterations_count"]
    tokens = state["total_tokens_generated"]
    veracity = state["last_veracity_score"]
    coherence = state["coherence_pct"]
    purpose = state.get("chat_purpose", "general purpose").upper()
    elapsed = int(time.time() - state["start_time"]) if state["start_time"] else 0
    mins, secs = divmod(elapsed, 60)

    veracity_color = "🟢" if veracity >= 85 else ("🟡" if veracity >= 60 else "🔴")
    topic_display = state["topic"] if state["topic"] else "*[None Specified]*"

    return (
        f"**Engine Status:** `{status}`\n\n"
        f"• **Chat Purpose Mode:** `{purpose}`\n"
        f"• **Active Focus:** `{topic_display}`\n"
        f"• **Coherence Target:** `{coherence}%`\n"
        f"• **Last Verified Reality:** {veracity_color} **`veracity: {veracity}%`**\n"
        f"• **Completed Loops:** `{passes}`\n"
        f"• **Tokens Generated:** ~`{tokens}`\n"
        f"• **Elapsed Time:** `{mins}m {secs}s`\n"
        f"• **Memory Buffer:** `{len(state['history_memory'])} turns`"
    )

# -----------------------------------------------------------------------------
# EXPORT UTILITIES
# -----------------------------------------------------------------------------
def export_last_output_md(chat_history: list) -> str:
    if not chat_history:
        return "# Output Box\n*No output recorded yet.*"

    last_assistant_msg = ""
    for msg in reversed(chat_history):
        if msg.get("role") == "assistant":
            last_assistant_msg = msg.get("content", "")
            break

    md_content = f"# Output Box Result\n\n**Timestamp:** `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`\n\n"
    md_content += last_assistant_msg
    return md_content

def export_full_chat_history_md(chat_history: list, state: dict) -> str:
    md_content = f"# Research Session Chat History\n\n**Target Goal:** `{state['initial_prompt']}` | **Purpose:** `{state.get('chat_purpose', 'general purpose')}`\n\n---\n\n"
    turn_number = 1
    i = 0
    while i < len(chat_history):
        user_msg = chat_history[i].get("content", "") if chat_history[i].get("role") == "user" else ""
        if user_msg: i += 1
        assistant_msg = chat_history[i].get("content", "") if i < len(chat_history) and chat_history[i].get("role") == "assistant" else ""
        if assistant_msg: i += 1

        md_content += f"### Turn {turn_number}\n\n#### Input:\n```markdown\n{user_msg}\n```\n\n#### Output:\n{assistant_msg}\n\n---\n\n"
        turn_number += 1

    return md_content

# -----------------------------------------------------------------------------
# CORE STREAMING & AUTONOMOUS LOOP ENGINE WITH AUTOMATED INJECTION
# -----------------------------------------------------------------------------
def run_research_iteration(chat_history: list, state: dict):
    if state["status"] != "RUNNING" or not state["topic"]:
        yield (chat_history, state, f"Status: {state['status']}", render_metrics(state), None, "", state["last_extracted_web_data"])
        return

    quantize_and_compress_history(state)
    web_llm_context, raw_web_content = search_duckduckgo_raw(state["topic"])
    state["last_extracted_web_data"] = raw_web_content

    chat_purpose = state.get("chat_purpose", "general purpose")
    purpose_directive = CHAT_PURPOSES.get(chat_purpose, CHAT_PURPOSES["general purpose"])
    coherence_val = state.get("coherence_pct", 90)

    temperature = 0.05 if chat_purpose == "coding" else max(0.05, round((100 - coherence_val) / 100.0, 2))
    top_p = max(0.1, round(coherence_val / 100.0, 2))

    system_prompt = f"### PURPOSE DIRECTIVE:\n{purpose_directive}\n\nSTRICT COHERENCE: {coherence_val}%."
    if chat_purpose in ["general purpose", "theory", "informative"]:
        system_prompt += "\nInclude formal LaTeX equations ($$...$$ or $...$) and Python lambdas when relevant."

    if state.get("custom_notes", "").strip():
        system_prompt += f"\n\nAdditional Notes:\n{state['custom_notes'].strip()}"

    pruned_memory = state["history_memory"][-MAX_CONTEXT_HISTORY_TURNS:]
    messages = [{"role": "system", "content": system_prompt}]
    if state["compressed_summary"]:
        messages.append({"role": "system", "content": f"Prior Context: {state['compressed_summary']}"})

    messages.extend(pruned_memory)
    current_prompt = f"{web_llm_context}\nDirectives: {state['context']}\nFocus Topic: {state['topic']}"
    messages.append({"role": "user", "content": current_prompt})

    payload = {
        "messages": messages,
        "stream": True,
        "temperature": temperature,
        "top_p": top_p,
        "max_tokens": MAX_OUTPUT_TOKENS,
    }

    user_display = f"🔍 **Loop #{state['iterations_count'] + 1} [{chat_purpose.upper()}]:** {state['topic']}"
    chat_history.append({"role": "user", "content": user_display})
    chat_history.append({"role": "assistant", "content": "..."})

    bot_response = ""
    latest_plot = None

    try:
        response = requests.post(KOBOLD_ENDPOINT, json=payload, stream=True, timeout=120)

        for line in response.iter_lines():
            if state["status"] in ["PAUSED", "STOPPED"]:
                bot_response += "\n\n*[Research Interrupted]*"
                chat_history[-1]["content"] = bot_response
                yield (chat_history, state, f"Status: {state['status']}", render_metrics(state), None, export_last_output_md(chat_history), raw_web_content)
                return

            if line:
                decoded_line = line.decode("utf-8").strip()
                if decoded_line.startswith("data: "):
                    content = decoded_line[6:]
                    if content == "[DONE]":
                        if state.get("auto_injection_enabled", True):
                            bot_response += inject_auto_interjection(bot_response, state)
                        break
                    try:
                        chunk = json.loads(content)
                        delta = chunk["choices"][0]["delta"].get("content", "")
                        bot_response += delta
                        chat_history[-1]["content"] = bot_response
                        yield (chat_history, state, f"🟢 RUNNING [{chat_purpose.upper()}]", render_metrics(state), None, export_last_output_md(chat_history), raw_web_content)
                    except Exception:
                        continue

        if chat_purpose == "coding":
            coding_result = execute_coding_cycle(
                bot_response,
                state["topic"],
                state["context"],
                state,
            )

            if not coding_result["approved"]:
                bot_response = coding_result["response"]
                chat_history[-1]["content"] = (
                    bot_response
                    + "\n\n⛔ **CURRENT DIRECTIVE REMAINS ACTIVE**\n"
                    + "The implementation has not produced an approved working signal. "
                    + "The next directive will not be generated."
                )
                yield (chat_history, state, "⛔ CODING REPAIR ACTIVE", render_metrics(state), latest_plot, export_last_output_md(chat_history), raw_web_content)
                return

            # Replace the displayed response with the final repaired implementation.
            bot_response = coding_result["response"]
            bot_response += "\n\n✅ **WORKING SIGNAL APPROVED** — progressing to the next directive."
            chat_history[-1]["content"] = bot_response

        elif chat_purpose in ["general purpose", "theory"]:
            lambdas_found = extract_and_test_lambdas(bot_response)
            if lambdas_found:
                bot_response += "\n\n### ⚡ Executable Lambda Verification:\n"
                for item in lambdas_found:
                    bot_response += f"- Code: `{item['expr']}` → Status: **{item['status']}**"
                    if item["status"] == "VALID":
                        bot_response += f" (Sample Mean: `{item['sample_eval']:.4f}`)"
                        if not latest_plot:
                            latest_plot = plot_lambda_function(item["fn"], item["expr"])
                    bot_response += "\n"

        veracity_score = evaluate_veracity_and_reality(bot_response, web_llm_context, coherence_val) if state.get("enable_veracity_check", True) else coherence_val
        state["last_veracity_score"] = veracity_score

        bot_response += f"\n\n---\n**veracity: {veracity_score}%**"
        chat_history[-1]["content"] = bot_response

        if chat_purpose == "coding":
            state["context"] = state.get("context", "")
            state["last_coding_signal"] = "APPROVED"

        state["history_memory"].append({"role": "user", "content": current_prompt})
        state["history_memory"].append({"role": "assistant", "content": bot_response})
        state["iterations_count"] += 1
        state["total_tokens_generated"] += estimate_tokens(bot_response)

        if state["auto_pilot"] and state["status"] == "RUNNING":
            chat_history.append({"role": "assistant", "content": "🤖 Reflector: Deriving next directive..."})
            yield (chat_history, state, "🟢 REFLECTING...", render_metrics(state), latest_plot, export_last_output_md(chat_history), raw_web_content)

            next_topic, next_directive = generate_next_research_directive(bot_response, state["topic"], state)
            state["topic"] = next_topic
            state["context"] = next_directive

            chat_history[-1]["content"] = f"🤖 **Next Directive:** `{next_topic}` | `{next_directive}`"
            yield (chat_history, state, f"🟢 RUNNING | Focus: '{next_topic}'", render_metrics(state), latest_plot, export_last_output_md(chat_history), raw_web_content)

    except Exception as e:
        chat_history[-1]["content"] = f"❌ Connection Error: {str(e)}"
        yield (chat_history, state, "Status: CONNECTION ERROR", render_metrics(state), None, export_last_output_md(chat_history), raw_web_content)

# -----------------------------------------------------------------------------
# CONTROL HANDLERS
# -----------------------------------------------------------------------------
def handle_start(topic: str, context_text: str, custom_notes_text: str, chat_purpose: str, coherence_val: int, veracity_toggle: bool, chat_history: list, state: dict):
    if not topic.strip():
        return (chat_history, state, "⚠️ Enter a topic first.", render_metrics(state), topic, context_text, custom_notes_text, None, "", state["last_extracted_web_data"])

    state["status"] = "RUNNING"
    state["topic"] = topic.strip()
    state["context"] = context_text.strip()
    state["custom_notes"] = custom_notes_text.strip()
    state["chat_purpose"] = chat_purpose
    state["initial_prompt"] = topic.strip()
    state["coherence_pct"] = coherence_val
    state["enable_veracity_check"] = veracity_toggle

    if not state["start_time"]:
        state["start_time"] = time.time()

    return (chat_history, state, f"🟢 RUNNING [{chat_purpose.upper()}]", render_metrics(state), "", "", "", None, "", state["last_extracted_web_data"])

def handle_pause(chat_history: list, state: dict):
    state["status"] = "PAUSED"
    return (chat_history, state, "⏸️ PAUSED", render_metrics(state), None, export_last_output_md(chat_history), state["last_extracted_web_data"])

def handle_stop(chat_history: list, state: dict):
    state["status"] = "STOPPED"
    return (chat_history, state, "⏹️ STOPPED", render_metrics(state), None, export_last_output_md(chat_history), state["last_extracted_web_data"])

def handle_interject(user_msg: str, chat_history: list, state: dict):
    if not user_msg.strip():
        return "", chat_history, state
    state["history_memory"].append({"role": "user", "content": f"[USER DIRECTIVE]: {user_msg}"})
    state["topic"] = user_msg.strip()
    chat_history.append({"role": "user", "content": f"⚡ Interjection: {user_msg}"})
    return "", chat_history, state

def handle_clean_session_ram(session_num: int, state: dict):
    fresh_state = create_default_execution_state()
    plt.close("all")
    gc.collect()
    return ([], fresh_state, "🧹 CLEARED", render_metrics(fresh_state), "", "", "", None, "", "No web search executed yet.")

def global_purge_system_ram():
    plt.close("all")
    gc.collect()
    return "🧹 Global Garbage Collector Executed: System RAM Purged."

# -----------------------------------------------------------------------------
# GRADIO UI SESSION TAB BUILDER
# -----------------------------------------------------------------------------
def build_session_tab(session_num: int):
    state = gr.State(create_default_execution_state)

    with gr.Row():
        gr.Markdown(f"### 📍 Session #{session_num} Controls")
        btn_close_tab = gr.Button("❌ Close Tab RAM", variant="stop", scale=0, min_width=200)

    with gr.Row():
        with gr.Column(scale=1):
            status_box = gr.Textbox(label="System Status", value="Status: STOPPED", interactive=False)
            chat_purpose_dropdown = gr.Dropdown(
                choices=["coding", "news", "informative", "theory", "general purpose"],
                value="general purpose",
                label="🎯 Output Mode"
            )

            topic_input = gr.Textbox(label="Active Topic", placeholder="Type topic...", lines=2)
            context_input = gr.Textbox(label="Active Directive", placeholder="Type instructions...", lines=2)
            custom_notes_input = gr.Textbox(label="📝 Notes", placeholder="Custom constraints...", lines=4)

            coherence_slider = gr.Slider(minimum=0, maximum=100, value=90, step=1, label="🎯 Coherence (%)")
            veracity_toggle = gr.Checkbox(value=True, label="🛡️ Veracity Check Engine")

            with gr.Row():
                btn_start = gr.Button("▶ START", variant="success")
                btn_pause = gr.Button("⏸ PAUSE", variant="warning")
            with gr.Row():
                btn_stop = gr.Button("⏹ STOP", variant="stop")
                btn_clean_ram = gr.Button("🧹 Clean RAM", variant="secondary")

            gr.Markdown("---")
            metrics_display = gr.Markdown(render_metrics(create_default_execution_state()))
            plot_display = gr.Plot(label="Dynamic Plot Visualizer")

            btn_copy_output = gr.Button("📋 Copy Output Box (.md)")
            btn_copy_history = gr.Button("📚 Copy History (.md)")
            export_markdown_display = gr.Code(label="Export Preview", language="markdown", interactive=False, lines=8)

        with gr.Column(scale=2):
            with gr.Tabs():
                with gr.Tab("💬 Research Chat & Output Stream"):
                    chatbot = gr.Chatbot(
                        label=f"Autonomous Stream (Session #{session_num})",
                        height=600,
                        latex_delimiters=[{"left": "$$", "right": "$$", "display": True}, {"left": "$", "right": "$", "display": False}],
                    )
                    with gr.Row():
                        user_interject = gr.Textbox(placeholder="Inject prompt...", show_label=False, scale=4)
                        btn_interject = gr.Button("⚡ Inject", scale=1, variant="primary")

                with gr.Tab("🌐 Web Search Results"):
                    web_extracted_display = gr.Markdown(value="*No search content yet.*")

    timer = gr.Timer(4.0)

    btn_start.click(
        fn=handle_start,
        inputs=[topic_input, context_input, custom_notes_input, chat_purpose_dropdown, coherence_slider, veracity_toggle, chatbot, state],
        outputs=[chatbot, state, status_box, metrics_display, topic_input, context_input, custom_notes_input, plot_display, export_markdown_display, web_extracted_display],
    )
    btn_pause.click(fn=handle_pause, inputs=[chatbot, state], outputs=[chatbot, state, status_box, metrics_display, plot_display, export_markdown_display, web_extracted_display])
    btn_stop.click(fn=handle_stop, inputs=[chatbot, state], outputs=[chatbot, state, status_box, metrics_display, plot_display, export_markdown_display, web_extracted_display])
    btn_interject.click(fn=handle_interject, inputs=[user_interject, chatbot, state], outputs=[user_interject, chatbot, state])
    btn_clean_ram.click(fn=lambda s: handle_clean_session_ram(session_num, s), inputs=[state], outputs=[chatbot, state, status_box, metrics_display, topic_input, context_input, custom_notes_input, plot_display, export_markdown_display, web_extracted_display])
    btn_copy_output.click(fn=export_last_output_md, inputs=[chatbot], outputs=[export_markdown_display])
    btn_copy_history.click(fn=export_full_chat_history_md, inputs=[chatbot, state], outputs=[export_markdown_display])

    timer.tick(
        fn=run_research_iteration,
        inputs=[chatbot, state],
        outputs=[chatbot, state, status_box, metrics_display, plot_display, export_markdown_display, web_extracted_display],
    )

    return btn_close_tab, [chatbot, state, status_box, metrics_display, topic_input, context_input, custom_notes_input, plot_display, export_markdown_display, web_extracted_display], state

# -----------------------------------------------------------------------------
# MAIN UI SETUP
# -----------------------------------------------------------------------------
with gr.Blocks(title="Autonomous Research Engine") as demo:
    gr.Markdown("# 🤖 Autonomous Research Engine with Purpose-Driven Chat Modes")

    active_tab_count = gr.State(1)

    with gr.Row():
        btn_panic = gr.Button("🚨 EMERGENCY PANIC BACKUP", variant="stop", scale=2)
        btn_add_session = gr.Button("➕ New Session Tab", variant="primary", scale=1)
        btn_global_ram_purge = gr.Button("🧹 Global RAM Purge", variant="secondary", scale=1)

    global_status_banner = gr.Markdown("")
    session_tabs, close_buttons, session_outputs_map, all_session_states, all_session_chatbots = [], [], {}, [], []

    with gr.Tabs(selected=0) as tabs_container:
        for i in range(1, MAX_SESSIONS + 1):
            with gr.Tab(f"Session {i}", visible=(i == 1), id=i - 1) as tab:
                close_btn, outputs, state_obj = build_session_tab(i)
                session_tabs.append(tab)
                close_buttons.append(close_btn)
                session_outputs_map[i - 1] = outputs
                all_session_states.append(state_obj)
                all_session_chatbots.append(outputs[0])

    btn_panic.click(fn=panic_emergency_backup, inputs=all_session_states + all_session_chatbots, outputs=[global_status_banner])
    btn_global_ram_purge.click(fn=global_purge_system_ram, inputs=[], outputs=[global_status_banner])

if __name__ == "__main__":
    # Example debug invocation for generated code snippet testing:
    sample_generated_code = """
import numpy as np

def run_pipeline():
    data = np.array([10, 20, 30, 40])
    print("Pipeline Execution Complete. Mean:", np.mean(data))

if __name__ == "__main__":
    run_pipeline()
"""
    # Trigger interactive debugging inside .venv_debug
    debug_and_auto_fix_in_venv(sample_generated_code)

    # Launch Gradio Application Interface
    demo.queue().launch(server_port=7879, theme=gr.themes.Soft())
