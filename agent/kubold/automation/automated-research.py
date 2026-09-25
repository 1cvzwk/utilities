import ast
import json
import re
import time
from datetime import datetime
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np
import requests
import gradio as gr
from duckduckgo_search import DDGS

# -----------------------------------------------------------------------------
# CONFIGURATION & GLOBAL STATE
# -----------------------------------------------------------------------------
KOBOLD_ENDPOINT = "http://localhost:5001/v1/chat/completions"
MAX_OUTPUT_TOKENS = 3072  # Maximum generation allowance per step
MAX_CONTEXT_HISTORY_TURNS = 6  # Keeps input dense & avoids exceeding model's context window

execution_state = {
    "status": "STOPPED",
    "topic": "",
    "context": "",
    "history_memory": [],
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

            # Test vector evaluation across a sample array
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
    """AUTONOMOUS REFLECTOR: Extract the single most coherent, valuable continuation step."""
    reflector_prompt = (
        f"You are a Meta-Research Lead analyzing the topic: '{current_topic}'.\n\n"
        f"Recent Findings Summary:\n\"\"\"\n{last_output[:1500]}\n\"\"\"\n\n"
        "Focus on content richness and actionable mathematical depth.\n"
        "Select the SINGLE MOST coherent next topic and concrete directive to investigate.\n"
        "Output strictly valid JSON with no markdown wrapping:\n"
        '{"next_topic": "Precise follow-up focus", "next_directive": "Specific mathematical or code task"}'
    )

    payload = {
        "messages": [
            {"role": "system", "content": "You output JSON only."},
            {"role": "user", "content": reflector_prompt},
        ],
        "temperature": 0.3,
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
    """Performs web search and returns formatted context block."""
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=3))
            if not results:
                return "No web results found."

            context = "\n=== REAL-TIME WEB CONTEXT ===\n"
            for i, r in enumerate(results, 1):
                context += f"[{i}] {r.get('title', '')}: {r.get('body', '')}\n"
            context += "=== END CONTEXT ===\n"
            return context
    except Exception as e:
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
# CORE STREAMING & AUTONOMOUS LOOP ENGINE
# -----------------------------------------------------------------------------
def run_research_iteration(chat_history: list):
    if execution_state["status"] != "RUNNING" or not execution_state["topic"]:
        yield chat_history, f"Status: {execution_state['status']}", render_metrics(), execution_state["topic"], execution_state["context"], None
        return

    web_context = search_duckduckgo(execution_state["topic"])

    system_prompt = (
        "You are an expert autonomous mathematical research agent. Prioritize rich, accurate information density.\n"
        "Provide:\n"
        "1. Formal LaTeX mathematical equations ($$...$$ for blocks, $...$ for inline).\n"
        "2. Equivalent, fully functional Python lambdas (`f = lambda x: ...`) using standard `np.` operations.\n"
        "3. High-value physical, analytical, or algorithmic insights."
    )

    # Context Window Pruning: Keep system prompt + last N turns to avoid input saturation
    pruned_memory = execution_state["history_memory"][-MAX_CONTEXT_HISTORY_TURNS:]
    messages = [{"role": "system", "content": system_prompt}]
    messages.extend(pruned_memory)

    current_prompt = f"{web_context}\nDirectives: {execution_state['context']}\nFocus Topic: {execution_state['topic']}"
    messages.append({"role": "user", "content": current_prompt})

    payload = {
        "messages": messages,
        "stream": True,
        "temperature": 0.5,
        "max_tokens": MAX_OUTPUT_TOKENS,  # Sets generation window upper bound
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
                yield chat_history, f"Status: {execution_state['status']}", render_metrics(), execution_state["topic"], execution_state["context"], None
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
                        yield chat_history, f"🟢 RUNNING | Focus: '{execution_state['topic']}'", render_metrics(), execution_state["topic"], execution_state["context"], None
                    except Exception:
                        continue

        # Extract, validate, and plot lambdas
        lambdas_found = extract_and_test_lambdas(bot_response)
        if lambdas_found:
            bot_response += "\n\n### ⚡ Executable Lambda Verification:\n"
            for item in lambdas_found:
                bot_response += f"- Code: `{item['expr']}` → Status: **{item['status']}**"
                if item["status"] == "VALID":
                    bot_response += f" (Sample Mean: `{item['sample_eval']:.4f}`)"
                    # Render plot for the first valid lambda found
                    if not latest_plot:
                        latest_plot = plot_lambda_function(item["fn"], item["expr"])
                bot_response += "\n"

        chat_history[-1]["content"] = bot_response

        # Memory Update
        execution_state["history_memory"].append({"role": "user", "content": current_prompt})
        execution_state["history_memory"].append({"role": "assistant", "content": bot_response})
        execution_state["iterations_count"] += 1
        execution_state["total_tokens_generated"] += estimate_tokens(bot_response)

        # Autonomous Reflector & Next Focus Injection
        if execution_state["auto_pilot"] and execution_state["status"] == "RUNNING":
            chat_history.append({
                "role": "assistant",
                "content": "🤖 *[Autonomous Controller]* Evaluating findings for the next optimal direction...",
            })
            yield chat_history, "🟢 REFLECTING...", render_metrics(), execution_state["topic"], execution_state["context"], latest_plot

            next_topic, next_directive = generate_next_research_directive(bot_response, execution_state["topic"])

            execution_state["topic"] = next_topic
            execution_state["context"] = next_directive

            chat_history[-1]["content"] = (
                f"🤖 **Auto-Injected Directive:**\n"
                f"- **Next Focus:** `{next_topic}`\n"
                f"- **Next Task:** `{next_directive}`"
            )

            yield chat_history, f"🟢 RUNNING | Focus: '{next_topic}'", render_metrics(), execution_state["topic"], execution_state["context"], latest_plot

    except Exception as e:
        chat_history[-1]["content"] = f"❌ Connection Error: {str(e)}"
        yield chat_history, "Status: CONNECTION ERROR", render_metrics(), execution_state["topic"], execution_state["context"], None


# -----------------------------------------------------------------------------
# CONTROL HANDLERS
# -----------------------------------------------------------------------------
def handle_start(topic: str, context_text: str, chat_history: list):
    if not topic.strip():
        return chat_history, "⚠️ Enter a topic first.", render_metrics(), topic, context_text, None

    execution_state["status"] = "RUNNING"
    execution_state["topic"] = topic.strip()
    execution_state["context"] = context_text.strip()
    if not execution_state["start_time"]:
        execution_state["start_time"] = time.time()

    return chat_history, f"🟢 RUNNING | Focus: '{execution_state['topic']}'", render_metrics(), execution_state["topic"], execution_state["context"], None


def handle_pause(chat_history: list):
    execution_state["status"] = "PAUSED"
    return chat_history, "⏸️ PAUSED", render_metrics(), execution_state["topic"], execution_state["context"], None


def handle_stop(chat_history: list):
    execution_state["status"] = "STOPPED"
    return chat_history, "🛑 STOPPED", render_metrics(), execution_state["topic"], execution_state["context"], None


def handle_interject(user_msg: str, chat_history: list):
    if not user_msg.strip():
        return "", chat_history
    execution_state["history_memory"].append({"role": "user", "content": f"[USER DIRECTIVE]: {user_msg}"})
    chat_history.append({"role": "user", "content": f"⚡ Interjection: {user_msg}"})
    return "", chat_history


# -----------------------------------------------------------------------------
# GRADIO UI
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# GRADIO UI (Updated for Gradio 6.0+)
# -----------------------------------------------------------------------------
# Remove parameters from gr.Blocks() constructor
with gr.Blocks() as demo:
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

        with gr.Column(scale=2):
            # Pass latex_delimiters directly to Chatbot or Markdown components if needed
            chatbot = gr.Chatbot(
                label="Autonomous Research Output Stream",
                height=650,
                latex_delimiters=[
                    {"left": "$$", "right": "$$", "display": True},
                    {"left": "$", "right": "$", "display": False}
                ]
            )
            with gr.Row():
                user_interject = gr.Textbox(placeholder="Inject custom prompt...", show_label=False, scale=4)
                btn_interject = gr.Button("⚡ Inject", scale=1, variant="primary")

    timer = gr.Timer(4.0)
    ui_outputs = [chatbot, status_box, metrics_display, topic_input, context_input, plot_display]

    btn_start.click(fn=handle_start, inputs=[topic_input, context_input, chatbot], outputs=ui_outputs)
    btn_pause.click(fn=handle_pause, inputs=[chatbot], outputs=ui_outputs)
    btn_stop.click(fn=handle_stop, inputs=[chatbot], outputs=ui_outputs)
    btn_interject.click(fn=handle_interject, inputs=[user_interject, chatbot], outputs=[user_interject, chatbot])

    timer.tick(fn=run_research_iteration, inputs=[chatbot], outputs=ui_outputs)

if __name__ == "__main__":
    # Pass theme inside launch()
    demo.queue().launch(server_port=7860, theme=gr.themes.Soft())
