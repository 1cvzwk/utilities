import ast
import base64
import io
import json
import re
import time
from datetime import datetime
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np
import requests
import gradio as gr
from ddgs import DDGS

# -----------------------------------------------------------------------------
# CONFIGURATION & GLOBAL STATE
# -----------------------------------------------------------------------------
KOBOLD_ENDPOINT = "http://localhost:5001/v1/chat/completions"
MAX_OUTPUT_TOKENS = 3096
MAX_CONTEXT_HISTORY_TURNS = 6

execution_state = {
    "status": "STOPPED",
    "topic": "Damped Harmonic Oscillators and Resonance",
    "context": "Derive differential equations, LaTeX blocks, and Python lambdas",
    "initial_prompt": "Damped Harmonic Oscillators and Resonance",
    "history_memory": [],
    "compressed_summary": "",
    "iterations_count": 0,
    "total_tokens_generated": 0,
    "start_time": None,
    "auto_pilot": True,
    "latest_valid_lambda": None,
}

# -----------------------------------------------------------------------------
# MATH, LAMBDA & PLOTTING UTILITIES
# -----------------------------------------------------------------------------
def extract_and_test_lambdas(text: str) -> list[dict]:
    """Parses text for Python lambda expressions, safely evaluates them, and returns validation status."""
    lambda_pattern = r"(lambda\s+[\w\s,]+:\s*[^`\n]+)"
    matches = re.findall(lambda_pattern, text)
    evaluated_results = []

    safe_globals = {
        "np": np,
        "sin": np.sin,
        "cos": np.cos,
        "tan": np.tan,
        "exp": np.exp,
        "sqrt": np.sqrt,
        "pi": np.pi,
        "log": np.log,
        "sinc": np.sinc,
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
                    "expr": expr,
                    "fn": fn,
                    "status": "VALID",
                    "sample_eval": float(np.mean(test_y)),
                })
        except Exception as e:
            evaluated_results.append({"expr": expr, "fn": None, "status": f"INVALID ({str(e)})"})

    return evaluated_results


def plot_lambda_function(fn, expr_str: str):
    """Generates a Matplotlib plot for a validated lambda function."""
    try:
        x = np.linspace(-10, 10, 400)
        y = fn(x)

        fig, ax = plt.subplots(figsize=(6, 3.5), dpi=100)
        ax.plot(x, y, color="#1f77b4", linewidth=2, label=f"`{expr_str}`")
        ax.axhline(0, color="gray", linestyle="--", linewidth=0.8)
        ax.axvline(0, color="gray", linestyle="--", linewidth=0.8)
        ax.grid(True, linestyle=":", alpha=0.6)
        ax.set_title("Dynamic Function Evaluation", fontsize=11)
        ax.set_xlabel("x")
        ax.set_ylabel("f(x)")
        ax.legend(loc="upper right", fontsize=8)
        plt.tight_layout()
        return fig
    except Exception:
        return None


def generate_next_research_directive(last_output: str, current_topic: str) -> tuple[str, str]:
    """SWAP DIRECTIVE ENGINE: Analyzes history/last output and generates next step aligned with original goal."""
    reflector_prompt = (
        f"Initial Research Goal: '{execution_state['initial_prompt']}'\n"
        f"Current Topic: '{current_topic}'\n\n"
        f"Latest Output Summary:\n\"\"\"\n{last_output[:1200]}\n\"\"\"\n\n"
        "Generate a NEW active research topic and directive that logically advances the original research goal.\n"
        "Output strictly valid JSON with no markdown formatting:\n"
        '{"next_topic": "New focused topic name", "next_directive": "Specific mathematical or coding instruction"}'
    )

    payload = {
        "messages": [
            {"role": "system", "content": "You output JSON only."},
            {"role": "user", "content": reflector_prompt},
        ],
        "temperature": 0.4,
        "max_tokens": 256,
    }

    try:
        res = requests.post(KOBOLD_ENDPOINT, json=payload, timeout=20)
        res_json = res.json()
        raw_text = res_json["choices"][0]["message"]["content"].strip()

        json_match = re.search(r"\{.*\}", raw_text, re.DOTALL)
        if json_match:
            data = json.loads(json_match.group(0))
            return data.get("next_topic", current_topic), data.get(
                "next_directive", "Deepen analytical formulation."
            )
    except Exception as e:
        print(f"Reflection error: {e}")

    return f"{current_topic} (Phase {execution_state['iterations_count'] + 1})", "Derive higher-order equations."


def search_duckduckgo(query: str) -> str:
    """Performs web search with debug logging output."""
    print(f"DEBUG: [WEB RESEARCH INITIALIZED] - Searching: '{query}'")
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=3))
            if not results:
                return "No web results found."

            context = "\n=== REAL-TIME WEB CONTEXT ===\n"
            for i, r in enumerate(results, 1):
                context += f"[{i}] {r.get('title', '')}: {r.get('body', '')}\n"
            context += "=== END CONTEXT ===\n"
            print("DEBUG: [WEB RESEARCH COMPLETE]")
            return context
    except Exception as e:
        print(f"DEBUG: [WEB RESEARCH FAILED] - {e}")
        return f"Web search failed: {str(e)}"


def estimate_tokens(text: str) -> int:
    return len(text.split()) * 4 // 3


def render_metrics() -> str:
    status = execution_state["status"]
    passes = execution_state["iterations_count"]
    tokens = execution_state["total_tokens_generated"]
    elapsed = int(time.time() - execution_state["start_time"]) if execution_state["start_time"] else 0
    mins, secs = divmod(elapsed, 60)

    return (
        f"**Engine Status:** `{status}`\n\n"
        f"• **Active Focus:** `{execution_state['topic']}`\n"
        f"• **Completed Loops:** `{passes}`\n"
        f"• **Tokens Generated:** ~`{tokens}`\n"
        f"• **Elapsed Time:** `{mins}m {secs}s`\n"
        f"• **Memory Buffer:** `{len(execution_state['history_memory'])} turns`"
    )


# -----------------------------------------------------------------------------
# .MD FORMATTING AND EXPORT UTILITIES (GITHUB README READY)
# -----------------------------------------------------------------------------
def export_last_output_md(chat_history: list) -> str:
    """Formats and returns the last output box in GitHub-compatible Markdown format."""
    if not chat_history:
        return "# Output Box\n*No output recorded yet.*"
    
    last_assistant_msg = ""
    for msg in reversed(chat_history):
        if msg.get("role") == "assistant":
            last_assistant_msg = msg.get("content", "")
            break

    md_content = f"# Output Box Result\n\n"
    md_content += f"**Timestamp:** `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`\n\n"
    md_content += "## Model Output\n\n"
    md_content += last_assistant_msg
    return md_content


def export_full_chat_history_md(chat_history: list) -> str:
    """Formats the entire chat history in GitHub README.md format with Input/Output blocks."""
    md_content = f"# Research Session Chat History\n\n"
    md_content += f"**Target Goal:** `{execution_state['initial_prompt']}`  \n"
    md_content += f"**Total Loops:** `{execution_state['iterations_count']}` | **Generated Tokens:** `{execution_state['total_tokens_generated']}`\n\n"
    md_content += "---\n\n"

    turn_number = 1
    i = 0
    while i < len(chat_history):
        user_msg = ""
        assistant_msg = ""

        if chat_history[i].get("role") == "user":
            user_msg = chat_history[i].get("content", "")
            i += 1

        if i < len(chat_history) and chat_history[i].get("role") == "assistant":
            assistant_msg = chat_history[i].get("content", "")
            i += 1

        md_content += f"### Turn {turn_number}\n\n"
        md_content += f"#### Input: box\n```markdown\n{user_msg}\n```\n\n"
        md_content += f"#### Output: box\n{assistant_msg}\n\n"
        md_content += "---\n\n"
        turn_number += 1

    return md_content


# -----------------------------------------------------------------------------
# CORE STREAMING & AUTONOMOUS LOOP ENGINE
# -----------------------------------------------------------------------------
def run_research_iteration(chat_history: list):
    if execution_state["status"] != "RUNNING" or not execution_state["topic"]:
        yield chat_history, f"Status: {execution_state['status']}", render_metrics(), execution_state["topic"], execution_state["context"], None, ""
        return

    web_context = search_duckduckgo(execution_state["topic"])

    system_prompt = (
        "You are an expert autonomous mathematical research agent. Prioritize rich, accurate information density.\n"
        "Provide:\n"
        "1. Formal LaTeX mathematical equations ($$...$$ for blocks, $...$ for inline).\n"
        "2. Equivalent, fully functional Python lambdas (`f = lambda x: ...`) using standard `np.` operations.\n"
        "3. High-value physical, analytical, or algorithmic insights."
    )

    # TOKEN CONSERVATION: Compress history window, keeping core goal + last N turns
    pruned_memory = execution_state["history_memory"][-MAX_CONTEXT_HISTORY_TURNS:]
    messages = [{"role": "system", "content": system_prompt}]
    
    if execution_state["compressed_summary"]:
        messages.append({"role": "system", "content": f"Prior Context Summary: {execution_state['compressed_summary']}"})
        
    messages.extend(pruned_memory)

    current_prompt = f"{web_context}\nDirectives: {execution_state['context']}\nFocus Topic: {execution_state['topic']}"
    messages.append({"role": "user", "content": current_prompt})

    payload = {
        "messages": messages,
        "stream": True,
        "temperature": 0.5,
        "max_tokens": MAX_OUTPUT_TOKENS,
    }

    user_display = f"🔍 **Loop #{execution_state['iterations_count'] + 1}:** {execution_state['topic']}"
    if execution_state["context"]:
        user_display += f" | *Directive:* {execution_state['context']}"

    chat_history.append({"role": "user", "content": user_display})
    chat_history.append({"role": "assistant", "content": "..."})

    bot_response = ""
    latest_plot = None

    try:
        response = requests.post(KOBOLD_ENDPOINT, json=payload, stream=True, timeout=120)

        for line in response.iter_lines():
            if execution_state["status"] in ["PAUSED", "STOPPED"]:
                bot_response += "\n\n*[Research Interrupted]*"
                chat_history[-1]["content"] = bot_response
                yield chat_history, f"Status: {execution_state['status']}", render_metrics(), execution_state["topic"], execution_state["context"], None, export_last_output_md(chat_history)
                return

            if line:
                decoded_line = line.decode("utf-8").strip()
                if decoded_line.startswith("data: "):
                    content = decoded_line[6:]
                    if content == "[DONE]":
                        break
                    try:
                        chunk = json.loads(content)
                        delta = chunk["choices"][0]["delta"].get("content", "")
                        bot_response += delta
                        chat_history[-1]["content"] = bot_response
                        yield chat_history, f"🟢 RUNNING | Focus: '{execution_state['topic']}'", render_metrics(), execution_state["topic"], execution_state["context"], None, export_last_output_md(chat_history)
                    except Exception:
                        continue

        # Extract, validate, and dynamically plot lambdas
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

        chat_history[-1]["content"] = bot_response

        # Memory Update
        execution_state["history_memory"].append({"role": "user", "content": current_prompt})
        execution_state["history_memory"].append({"role": "assistant", "content": bot_response})
        execution_state["iterations_count"] += 1
        execution_state["total_tokens_generated"] += estimate_tokens(bot_response)

        # Swapping Directives & Autonomous Reflector Loop
        if execution_state["auto_pilot"] and execution_state["status"] == "RUNNING":
            chat_history.append({
                "role": "assistant",
                "content": "🤖 *[Autonomous Reflector]* Evaluating research progress and generating next directive...",
            })
            yield chat_history, "🟢 REFLECTING...", render_metrics(), execution_state["topic"], execution_state["context"], latest_plot, export_last_output_md(chat_history)

            next_topic, next_directive = generate_next_research_directive(bot_response, execution_state["topic"])

            execution_state["topic"] = next_topic
            execution_state["context"] = next_directive

            chat_history[-1]["content"] = (
                f"🤖 **Swapped Active Directive:**\n"
                f"- **Next Topic Focus:** `{next_topic}`\n"
                f"- **Next Research Task:** `{next_directive}`"
            )

            yield chat_history, f"🟢 RUNNING | Focus: '{next_topic}'", render_metrics(), execution_state["topic"], execution_state["context"], latest_plot, export_last_output_md(chat_history)

    except Exception as e:
        chat_history[-1]["content"] = f"❌ Connection Error: {str(e)}"
        yield chat_history, "Status: CONNECTION ERROR", render_metrics(), execution_state["topic"], execution_state["context"], None, export_last_output_md(chat_history)


# -----------------------------------------------------------------------------
# CONTROL HANDLERS
# -----------------------------------------------------------------------------
def handle_start(topic: str, context_text: str, chat_history: list):
    if not topic.strip():
        return chat_history, "⚠️ Enter a topic first.", render_metrics(), topic, context_text, None, ""

    execution_state["status"] = "RUNNING"
    execution_state["topic"] = topic.strip()
    execution_state["context"] = context_text.strip()
    execution_state["initial_prompt"] = topic.strip()
    if not execution_state["start_time"]:
        execution_state["start_time"] = time.time()

    return chat_history, f"🟢 RUNNING | Focus: '{execution_state['topic']}'", render_metrics(), execution_state["topic"], execution_state["context"], None, ""


def handle_pause(chat_history: list):
    execution_state["status"] = "PAUSED"
    return chat_history, "⏸️ PAUSED", render_metrics(), execution_state["topic"], execution_state["context"], None, export_last_output_md(chat_history)


def handle_stop(chat_history: list):
    execution_state["status"] = "STOPPED"
    return chat_history, "⏹️ STOPPED", render_metrics(), execution_state["topic"], execution_state["context"], None, export_last_output_md(chat_history)


def handle_interject(user_msg: str, chat_history: list):
    if not user_msg.strip():
        return "", chat_history
    execution_state["history_memory"].append({"role": "user", "content": f"[USER DIRECTIVE]: {user_msg}"})
    execution_state["topic"] = user_msg.strip()
    chat_history.append({"role": "user", "content": f"⚡ Swapped Topic Interjection: {user_msg}"})
    return "", chat_history


# -----------------------------------------------------------------------------
# GRADIO UI
# -----------------------------------------------------------------------------
with gr.Blocks(title="Autonomous Research Engine") as demo:
    gr.Markdown("# 🤖 Autonomous Research & Dynamic Plotting Engine")

    with gr.Row():
        with gr.Column(scale=1):
            status_box = gr.Textbox(label="System Status", value="Status: STOPPED", interactive=False)
            topic_input = gr.Textbox(label="Active Research Topic", value="Damped Harmonic Oscillators and Resonance", lines=2)
            context_input = gr.Textbox(label="Active Directive", value="Derive differential equations, LaTeX blocks, and Python lambdas", lines=2)

            with gr.Row():
                btn_start = gr.Button("▶ START", variant="success")
                btn_pause = gr.Button("⏸ PAUSE", variant="warning")
            with gr.Row():
                btn_stop = gr.Button("⏹ STOP", variant="stop")

            gr.Markdown("---")
            metrics_display = gr.Markdown(render_metrics())
            plot_display = gr.Plot(label="Dynamic Plot Visualizer")

            gr.Markdown("### 📄 Export Tools (.md)")
            btn_copy_output = gr.Button("📋 Copy Output Box (.md)")
            btn_copy_history = gr.Button("📚 Copy Entire History (.md)")
            export_markdown_display = gr.Code(label="Exported Markdown Preview (README.md Ready)", language="markdown", interactive=False, lines=10)

        with gr.Column(scale=2):
            chatbot = gr.Chatbot(
                label="Autonomous Research Output Stream",
                height=650,
                latex_delimiters=[
                    {"left": "$$", "right": "$$", "display": True},
                    {"left": "$", "right": "$", "display": False},
                ]
            )
            with gr.Row():
                user_interject = gr.Textbox(placeholder="Inject custom prompt or swap topic...", show_label=False, scale=4)
                btn_interject = gr.Button("⚡ Inject / Swap", scale=1, variant="primary")

    timer = gr.Timer(4.0)
    ui_outputs = [chatbot, status_box, metrics_display, topic_input, context_input, plot_display, export_markdown_display]

    btn_start.click(fn=handle_start, inputs=[topic_input, context_input, chatbot], outputs=ui_outputs)
    btn_pause.click(fn=handle_pause, inputs=[chatbot], outputs=ui_outputs)
    btn_stop.click(fn=handle_stop, inputs=[chatbot], outputs=ui_outputs)
    btn_interject.click(fn=handle_interject, inputs=[user_interject, chatbot], outputs=[user_interject, chatbot])

    btn_copy_output.click(fn=export_last_output_md, inputs=[chatbot], outputs=[export_markdown_display])
    btn_copy_history.click(fn=export_full_chat_history_md, inputs=[chatbot], outputs=[export_markdown_display])

    timer.tick(fn=run_research_iteration, inputs=[chatbot], outputs=ui_outputs)

if __name__ == "__main__":
    demo.queue().launch(server_port=7860, theme=gr.themes.Soft())
