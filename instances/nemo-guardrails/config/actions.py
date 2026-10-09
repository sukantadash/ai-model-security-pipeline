"""Custom NeMo Guardrails actions for the AI Model Security Pipeline.

Based on the RHOAI 3.2 guide example (check_message_length, check_forbidden_words),
extended with jailbreak / prompt-injection input checks and an output compliance check.

Tunables (env on the NemoGuardrails CR):
  NEMO_MAX_WORDS  word limit per user message (default 300)
"""
import os
import re
from typing import Optional

from nemoguardrails.actions import action

MAX_WORDS = int(os.environ.get("NEMO_MAX_WORDS", "300"))

FORBIDDEN_TOPICS = {
    "security": ["password", "hack", "exploit", "malware", "ransomware", "keylogger"],
    "inappropriate": ["violence", "illegal", "harmful", "weapon", "explosive"],
}

# Input patterns that try to override the system prompt or safety policy.
JAILBREAK_PATTERNS = [
    r"\bignore (all |any )?(the )?(previous|prior|above) (instructions|rules|prompts?)\b",
    r"\bdisregard (all |any )?(the )?(previous|prior|above|your) (instructions|rules|guidelines)\b",
    r"\byou are (now )?dan\b",
    r"\bdo anything now\b",
    r"\bdeveloper mode\b",
    r"\bno (restrictions|rules|filters|limits)\b",
    r"\b(reveal|print|show|repeat|output) (me )?(your|the) (system|hidden|initial) (prompt|instructions)\b",
    r"\bjailbreak\b",
    r"\bpretend (that )?you (have|are under) no\b",
    r"\bact as an? (unfiltered|uncensored|unrestricted)\b",
]

# Output phrases that indicate the model accepted a jailbreak persona.
OUTPUT_COMPLIANCE_PATTERNS = [
    r"\bas dan\b",
    r"\bdeveloper mode (is )?enabled\b",
    r"\bi have no restrictions\b",
    r"\bno restrictions apply\b",
    r"\bjailbreak (mode )?(successful|activated)\b",
]


def _words(text: str) -> set:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


@action(is_system_action=True)
async def check_message_length(context: Optional[dict] = None) -> str:
    """Check if user message is within acceptable length limits."""
    user_message = (context or {}).get("user_message", "") or ""
    word_count = len(user_message.split())
    if word_count > MAX_WORDS:
        return "blocked_too_long"
    if word_count > MAX_WORDS * 0.8:
        return "warning_long"
    return "allowed"


@action(is_system_action=True)
async def check_forbidden_words(context: Optional[dict] = None) -> str:
    """Check for forbidden words or topics (whole-word match)."""
    words = _words((context or {}).get("user_message", "") or "")
    for category, forbidden in FORBIDDEN_TOPICS.items():
        for word in forbidden:
            if word in words:
                return f"blocked_{category}_{word}"
    return "allowed"


@action(is_system_action=True)
async def check_jailbreak_attempt(context: Optional[dict] = None) -> str:
    """Block common jailbreak / prompt-injection phrasings."""
    user_message = ((context or {}).get("user_message", "") or "").lower()
    for pattern in JAILBREAK_PATTERNS:
        if re.search(pattern, user_message):
            return "blocked_jailbreak"
    return "allowed"


@action(is_system_action=True)
async def check_output_compliance(context: Optional[dict] = None) -> str:
    """Block bot replies that show the model adopted a jailbreak persona."""
    bot_message = ((context or {}).get("bot_message", "") or "").lower()
    for pattern in OUTPUT_COMPLIANCE_PATTERNS:
        if re.search(pattern, bot_message):
            return "blocked_output_compliance"
    return "allowed"
