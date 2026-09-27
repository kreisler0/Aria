// The fixed tool schema (spec §3), identical to shared/ai/tools.json — the same list the iOS
// and Windows apps send. It is the only way the assistant can change data: every call is
// validated and run by executor.js, never as SQL. tests/core.test.mjs checks it against the
// shared file.

export const TOOL_NAMES = ["create_task", "complete_task", "delete_task", "create_event", "delete_event", "reschedule_event", "list_tasks_for_range", "list_events_for_range"];

export const TOOLS = [
  {
    "function": {
      "description": "Create a new to-do item",
      "name": "create_task",
      "parameters": {
        "properties": {
          "due_at": {
            "description": "When the task is due, ISO 8601 with UTC offset, e.g. 2026-10-02T17:00:00-04:00",
            "format": "date-time",
            "type": "string"
          },
          "notes": {
            "description": "Optional details",
            "type": "string"
          },
          "priority": {
            "description": "0=none, 1=low, 2=medium, 3=high",
            "enum": [
              0,
              1,
              2,
              3
            ],
            "type": "integer"
          },
          "title": {
            "description": "Short title of the task",
            "type": "string"
          }
        },
        "required": [
          "title"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "Mark an existing task as done",
      "name": "complete_task",
      "parameters": {
        "properties": {
          "task_id": {
            "description": "The id of the task",
            "type": "string"
          }
        },
        "required": [
          "task_id"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "Delete an existing task permanently",
      "name": "delete_task",
      "parameters": {
        "properties": {
          "task_id": {
            "description": "The id of the task",
            "type": "string"
          }
        },
        "required": [
          "task_id"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "Create a calendar event",
      "name": "create_event",
      "parameters": {
        "properties": {
          "all_day": {
            "description": "True for an all-day event",
            "type": "boolean"
          },
          "end_at": {
            "description": "End, ISO 8601 with UTC offset",
            "format": "date-time",
            "type": "string"
          },
          "start_at": {
            "description": "Start, ISO 8601 with UTC offset",
            "format": "date-time",
            "type": "string"
          },
          "title": {
            "description": "Title of the event",
            "type": "string"
          }
        },
        "required": [
          "title",
          "start_at",
          "end_at"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "Delete an existing calendar event",
      "name": "delete_event",
      "parameters": {
        "properties": {
          "event_id": {
            "description": "The id of the event",
            "type": "string"
          }
        },
        "required": [
          "event_id"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "Move an existing calendar event to a new start and end time",
      "name": "reschedule_event",
      "parameters": {
        "properties": {
          "event_id": {
            "description": "The id of the event",
            "type": "string"
          },
          "new_end_at": {
            "description": "New end, ISO 8601 with UTC offset",
            "format": "date-time",
            "type": "string"
          },
          "new_start_at": {
            "description": "New start, ISO 8601 with UTC offset",
            "format": "date-time",
            "type": "string"
          }
        },
        "required": [
          "event_id",
          "new_start_at",
          "new_end_at"
        ],
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "List tasks due between two dates (inclusive, in the user's time zone). Omit both dates to list every open task, including tasks without a due date.",
      "name": "list_tasks_for_range",
      "parameters": {
        "properties": {
          "end": {
            "description": "Last day, YYYY-MM-DD",
            "format": "date",
            "type": "string"
          },
          "start": {
            "description": "First day, YYYY-MM-DD",
            "format": "date",
            "type": "string"
          }
        },
        "type": "object"
      }
    },
    "type": "function"
  },
  {
    "function": {
      "description": "List calendar events between two dates (inclusive, in the user's time zone). Omit both dates for the next 7 days.",
      "name": "list_events_for_range",
      "parameters": {
        "properties": {
          "end": {
            "description": "Last day, YYYY-MM-DD",
            "format": "date",
            "type": "string"
          },
          "start": {
            "description": "First day, YYYY-MM-DD",
            "format": "date",
            "type": "string"
          }
        },
        "type": "object"
      }
    },
    "type": "function"
  }
];
