# OpenAI API — Responses API reference (extracted)

Curated extraction from `openai/openai-openapi` `openapi.json` (fetched 2025-08-10). Full spec: https://github.com/openai/openai-openapi — re-fetch for updates.

## Endpoints (non-beta `/responses`)

| Method | Path | Summary |
|--------|------|---------|
| POST | `/responses` | Creates a model response. Provide [text](/docs/guides/text) or [image](/docs/guides/images) inputs to generate [text](/docs/guides/text) or [JSON](/docs/guides/structured-outputs) outputs. Have the model call your own [custom code](/docs/guides/function-calling) or use built-in [tools](/docs/guides/tools) like [web search](/docs/guides/tools-web-search) or [file search](/docs/guides/tools-file-search) to use your own data as input for the model's response. |
| POST | `/responses/compact` | Compact a conversation. Returns a compacted response object.  Learn when and how to compact long-running conversations in the [conversation state guide](/docs/guides/conversation-state#managing-the-context-window). For ZDR-compatible compaction details, see [Compaction (advanced)](/docs/guides/conversation-state#compaction-advanced). |
| POST | `/responses/input_tokens` | Returns input token counts of the request.  Returns an object with `object` set to `response.input_tokens` and an `input_tokens` count. |
| GET | `/responses/{response_id}` | Retrieves a model response with the given ID. |
| DELETE | `/responses/{response_id}` | Deletes a model response with the given ID. |
| POST | `/responses/{response_id}/cancel` | Cancels a model response with the given ID. Only responses created with the `background` parameter set to `true` can be cancelled.  [Learn more](/docs/guides/background). |
| GET | `/responses/{response_id}/input_items` | Returns a list of input items for a given response. |

## POST /responses — request body

`CreateResponse` = `CreateModelResponseProperties` + `ResponseProperties` + inline. Key fields:

  - `metadata` — Metadata — 
  - `top_logprobs` — integer — An integer between 0 and 20 specifying the maximum number of most likely tokens to return at each token position, each with an associated log probability. In some cases, the number of returned tokens 
  - `temperature` — number | null — 
  - `top_p` — number | null — 
  - `user` — string — This field is being replaced by `safety_identifier` and `prompt_cache_key`. Use `prompt_cache_key` instead to maintain caching optimizations. A stable identifier for your end-users. Used to boost cach
  - `safety_identifier` — string | null — 
  - `prompt_cache_key` — string | null — 
  - `service_tier` — ServiceTier — 
  - `prompt_cache_retention` — string | null — 
  - `prompt_cache_options` — PromptCacheOptionsParam — 
  - `previous_response_id` — string | null — 
  - `model` — ModelIdsResponses — Model ID used to generate the response, like `gpt-4o` or `o3`. OpenAI offers a wide range of models with different capabilities, performance characteristics, and price points. Refer to the [model guid
  - `background` — boolean | null — 
  - `max_tool_calls` — integer | null — 
  - `text` — ResponseTextParam — 
  - `tools` — ToolsArray — 
  - `tool_choice` — ToolChoiceParam — 
  - `prompt` — Prompt — 
  - `truncation` — string | null — 
  - `reasoning` — Reasoning | null — 
  - `input` — InputParam — 
  - `include` — array | null — 
  - `parallel_tool_calls` — boolean | null — 
  - `store` — boolean | null — 
  - `instructions` — string | null — 
  - `moderation` — ModerationParam | null — 
  - `stream` — boolean | null — 
  - `stream_options` — ResponseStreamOptions — 
  - `conversation` — ConversationParam | null — 
  - `context_management` — array | null — 
  - `max_output_tokens` — integer | null — 

## Response object

`Response` = `ModelResponseProperties` + `ResponseProperties` + inline. Key fields:

  - `metadata` — Metadata — 
  - `top_logprobs` — integer | null — 
  - `temperature` — number | null — 
  - `top_p` — number | null — 
  - `user` — string — This field is being replaced by `safety_identifier` and `prompt_cache_key`. Use `prompt_cache_key` instead to maintain caching optimizations. A stable identifier for your end-users. Used to boost cach
  - `safety_identifier` — string | null — 
  - `prompt_cache_key` — string | null — 
  - `service_tier` — ServiceTier — 
  - `prompt_cache_retention` — string | null — 
  - `previous_response_id` — string | null — 
  - `model` — ModelIdsResponses — Model ID used to generate the response, like `gpt-4o` or `o3`. OpenAI offers a wide range of models with different capabilities, performance characteristics, and price points. Refer to the [model guid
  - `background` — boolean | null — 
  - `max_tool_calls` — integer | null — 
  - `text` — ResponseTextParam — 
  - `tools` — ToolsArray — 
  - `tool_choice` — ToolChoiceParam — 
  - `prompt` — Prompt — 
  - `truncation` — string | null — 
  - `id` — string — Unique identifier for this Response.
  - `object` — string (response) — The object type of this resource - always set to `response`.
  - `status` — string (completed, failed, in_progress, cancelled) — The status of the response generation. One of `completed`, `failed`, `in_progress`, `cancelled`, `queued`, or `incomplete`.
  - `created_at` — number — Unix timestamp (in seconds) of when this Response was created.
  - `completed_at` — number | null — 
  - `error` — ResponseError — 
  - `incomplete_details` — object | null — 
  - `output` — array[OutputItem] — An array of content items generated by the model.  - The length and order of items in the `output` array is dependent   on the model's response. - Rather than accessing the first item in the `output` 
  - `reasoning` — Reasoning | null — 
  - `instructions` — ? | null — 
  - `output_text` — string | null — 
  - `usage` — ResponseUsage — 
  - `prompt_cache_options` — PromptCacheOptions — 
  - `moderation` — Moderation | null — 
  - `parallel_tool_calls` — boolean — Whether to allow the model to run tool calls in parallel.
  - `conversation` — ResponseConversation | null — 
  - `max_output_tokens` — integer | null — 

## Output items (discriminated by `type`)

The `output` array contains one or more of (curated subset of `OutputItem` oneOf):

### `OutputMessage` — type `message`
An output message from the model.

  - `id` — string — The unique ID of the output message.
  - `type` — string (message) — The type of the output message. Always `message`.
  - `role` — string (assistant) — The role of the output message. Always `assistant`.
  - `content` — array[OutputMessageContent] — The content of the output message.
  - `phase` — MessagePhase | null — 
  - `status` — string (in_progress, completed, incomplete) — The status of the message input. One of `in_progress`, `completed`, or `incomplete`. Populated when input items are returned via API.

### `FunctionToolCall` — type `function_call`
A tool call to run a function. See the  [function calling guide](/docs/guides/function-calling) for more information.

  - `id` — string — The unique ID of the function tool call.
  - `type` — string (function_call) — The type of the function tool call. Always `function_call`.
  - `call_id` — string — The unique ID of the function tool call generated by the model.
  - `caller` — ToolCallCaller | null — 
  - `namespace` — string — The namespace of the function to run.
  - `name` — string — The name of the function to run.
  - `arguments` — string — A JSON string of the arguments to pass to the function.
  - `status` — string (in_progress, completed, incomplete) — The status of the item. One of `in_progress`, `completed`, or `incomplete`. Populated when items are returned via API.

### `FunctionToolCallOutputResource` — type `?`


### `CustomToolCall` — type `custom_tool_call`
A call to a custom tool created by the model.

  - `type` — string (custom_tool_call) — The type of the custom tool call. Always `custom_tool_call`.
  - `id` — string — The unique ID of the custom tool call in the OpenAI platform.
  - `call_id` — string — An identifier used to map this custom tool call to a tool call output.
  - `caller` — ToolCallCaller | null — 
  - `namespace` — string — The namespace of the custom tool being called.
  - `name` — string — The name of the custom tool being called.
  - `input` — string — The input for the custom tool call generated by the model.

### `CustomToolCallOutputResource` — type `?`


### `ReasoningItem` — type `reasoning`
A description of the chain of thought used by a reasoning model while generating a response. Be sure to include these items in your `input` to the Responses API

  - `type` — string (reasoning) — The type of the object. Always `reasoning`.
  - `id` — string — The unique identifier of the reasoning content.
  - `encrypted_content` — string | null — 
  - `summary` — array[SummaryTextContent] — Reasoning summary content.
  - `content` — array[ReasoningTextContent] — Reasoning text content.
  - `status` — string (in_progress, completed, incomplete) — The status of the item. One of `in_progress`, `completed`, or `incomplete`. Populated when items are returned via API.

### `WebSearchToolCall` — type `web_search_call`
The results of a web search tool call. See the [web search guide](/docs/guides/tools-web-search) for more information.

  - `id` — string — The unique ID of the web search tool call.
  - `type` — string (web_search_call) — The type of the web search tool call. Always `web_search_call`.
  - `status` — string (in_progress, searching, completed, failed) — The status of the web search tool call.
  - `action` — object — An object describing the specific action taken in this web search call. Includes details on how the model used the web (search, open_page, find_in_page).

### `CodeInterpreterToolCall` — type `code_interpreter_call`
A tool call to run code.

  - `type` — string (code_interpreter_call) — The type of the code interpreter tool call. Always `code_interpreter_call`.
  - `id` — string — The unique ID of the code interpreter tool call.
  - `status` — string (in_progress, completed, incomplete, interpreting) — The status of the code interpreter tool call. Valid values are `in_progress`, `completed`, `incomplete`, `interpreting`, and `failed`.
  - `container_id` — string — The ID of the container used to run the code.
  - `code` — string | null — 
  - `outputs` — array | null — 

### `MCPToolCall` — type `mcp_call`
An invocation of a tool on an MCP server.

  - `type` — string (mcp_call) — The type of the item. Always `mcp_call`.
  - `id` — string — The unique ID of the tool call.
  - `server_label` — string — The label of the MCP server running the tool.
  - `name` — string — The name of the tool that was run.
  - `arguments` — string — A JSON string of the arguments passed to the tool.
  - `output` — string | null — 
  - `error` — string | null — 
  - `status` — MCPToolCallStatus — The status of the tool call. One of `in_progress`, `completed`, `incomplete`, `calling`, or `failed`.
  - `approval_request_id` — string | null — 

## Streaming (SSE) events

`stream: true` yields `data: <json>` lines with `type` discriminator; the stream ends with `response.completed` or `response.failed`. Core events for a text/tool-call server:

- **`response.created`** (`ResponseCreatedEvent`) — An event that is emitted when a response is created.
- **`response.in_progress`** (`ResponseInProgressEvent`) — Emitted when the response is in progress.
- **`response.output_item.added`** (`ResponseOutputItemAddedEvent`) — Emitted when a new output item is added.
- **`response.content_part.added`** (`ResponseContentPartAddedEvent`) — Emitted when a new content part is added.
- **`?`** (`ResponseOutputTextDeltaEvent`) — 
- **`?`** (`ResponseOutputTextDoneEvent`) — 
- **`response.function_call_arguments.delta`** (`ResponseFunctionCallArgumentsDeltaEvent`) — Emitted when there is a partial function-call arguments delta.
- **`response.function_call_arguments.done`** (`ResponseFunctionCallArgumentsDoneEvent`) — Emitted when function-call arguments are finalized.
- **`response.output_item.done`** (`ResponseOutputItemDoneEvent`) — Emitted when an output item is marked done.
- **`response.completed`** (`ResponseCompletedEvent`) — Emitted when the model response is complete.
- **`response.failed`** (`ResponseFailedEvent`) — An event that is emitted when a response fails.
- **`response.incomplete`** (`ResponseIncompleteEvent`) — An event that is emitted when a response finishes as incomplete.
- **`error`** (`ResponseErrorEvent`) — Emitted when an error occurs.

Other event families in the spec: audio (`ResponseAudio*`), reasoning (`ResponseReasoning*`), refusal, annotations, file/web/MCP tool calls, image gen, code interpreter.

## Tools (`tools` request param)

- `FunctionTool` (type `function`) — Defines a function in your own code the model can choose to call. Learn more about [function calling](https://platform.openai.com/docs/guides/function-calling).
- `FileSearchTool` (type `file_search`) — A tool that searches for relevant content from uploaded files. Learn more about the [file search tool](https://platform.openai.com/docs/guides/tools-file-search
- `ComputerTool` (type `computer`) — A tool that controls a virtual computer. Learn more about the [computer tool](https://platform.openai.com/docs/guides/tools-computer-use).
- `ComputerUsePreviewTool` (type `computer_use_preview`) — A tool that controls a virtual computer. Learn more about the [computer tool](https://platform.openai.com/docs/guides/tools-computer-use).
- `WebSearchTool` (type `web_search`) — Search the Internet for sources related to the prompt. Learn more about the [web search tool](/docs/guides/tools-web-search).
- `MCPTool` (type `mcp`) — Give the model access to additional tools via remote Model Context Protocol (MCP) servers. [Learn more about MCP](/docs/guides/tools-remote-mcp).
- `CodeInterpreterTool` (type `code_interpreter`) — A tool that runs Python code to help generate a response to a prompt.
- `ProgrammaticToolCallingParam` (type `programmatic_tool_calling`) — 
- `ImageGenTool` (type `image_generation`) — A tool that generates images using the GPT image models.
- `LocalShellToolParam` (type `local_shell`) — A tool that allows the model to execute shell commands in a local environment.
- `FunctionShellToolParam` (type `shell`) — A tool that allows the model to execute shell commands.
- `CustomToolParam` (type `custom`) — A custom tool that processes input using a specified format. Learn more about   [custom tools](/docs/guides/function-calling#custom-tools)
- `NamespaceToolParam` (type `namespace`) — Groups function/custom tools under a shared namespace.
- `ToolSearchToolParam` (type `tool_search`) — Hosted or BYOT tool search configuration for deferred tools.
- `WebSearchPreviewTool` (type `web_search_preview`) — This tool searches the web for relevant results to use in a response. Learn more about the [web search tool](https://platform.openai.com/docs/guides/tools-web-s
- `ApplyPatchToolParam` (type `apply_patch`) — Allows the assistant to create, delete, or update files using unified diffs.

## Auth & transport

- Base URL: `https://api.openai.com/v1`
- Auth: `Authorization: Bearer <OPENAI_API_KEY>`
- Content-Type: `application/json`
- Streaming: SSE (`text/event-stream`); `stream: true`, optionally `stream_options.include_usage` for token usage in the final event
