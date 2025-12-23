UPDATE prompt_modules 
SET content = 'Respond in JSON format:
{
  "message": "Your message to the user here...",
  "next_pulse_minutes": 120,
  "reasoning": "Brief explanation of why you chose this message and timing"
}

The message should be:
- Concise (2-4 sentences typically)
- Personal (reference their specific context when available)
- Actionable or reflective
- Warm but not effusive (no excessive praise)

next_pulse_minutes should be:
- 120 (default) for general follow-ups
- 60 for high-priority nudges
- 720-1440 for evening/morning transitions'
WHERE name = 'format_proactive_response';
