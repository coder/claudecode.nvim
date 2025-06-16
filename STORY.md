# The Story: How I Reverse-Engineered Claude's IDE Protocol

## The Reddit Post That Started Everything

While browsing Reddit at DevOpsCon in London, I stumbled upon a post that caught my eye: someone mentioned finding .vsix files in Anthropic's npm package for their Claude Code VS Code extension.

Link to the Reddit post: <https://www.reddit.com/r/ClaudeAI/comments/1klpzvl/hidden_jetbrains_vs_code_plugin_in_todays_release/>

My first thought? "No way, they wouldn't ship the source like that."

But curiosity got the better of me. I checked npm, and there they were — the .vsix files, just sitting in the vendor folder.

## Down the Rabbit Hole

A .vsix file is just a fancy ZIP archive. So naturally, I decompressed it. What I found was a single line of minified JavaScript — 10,000 lines worth when prettified. Completely unreadable.

But here's where it gets interesting. I'd been playing with AST-grep, a tool that combines the power of grep with tree-sitter for semantic code understanding. Instead of just searching text, it understands code structure.

## Using AI to Understand AI

I had a crazy idea: What if I used Claude to help me understand Claude's own extension?

I fed the prettified code to Claude and asked it to write AST-grep queries to rename obfuscated variables based on their usage patterns. For example:

```javascript
// Before
const L = new McpToolRegistry();

// After
const toolRegistry = new McpToolRegistry();
```

Suddenly, patterns emerged. Functions revealed their purpose. The fog lifted.

## The Discovery

What I discovered was fascinating:

1. **It's all MCP** — The extensions use Model Context Protocol, but with a twist
2. **WebSocket Transport** — Unlike standard MCP (which uses stdio/HTTP), these use WebSockets
3. **Claude-Specific** — Claude Code is the only MCP client that supports WebSocket transport
4. **Simple Protocol** — The IDE creates a server, Claude connects to it

## Building for Neovim

Armed with this knowledge, I faced a new challenge: I wanted this in Neovim, but I didn't know Lua.

So I did what any reasonable person would do in 2025 — I used AI to help me build it. Using Roo Code with Gemini 2.5 Pro, I scaffolded a Neovim plugin that implements the same protocol. (Note: Claude 4 models were not publicly available at the time of writing the extension.)

The irony isn't lost on me: I used AI to reverse-engineer an AI tool, then used AI to build a plugin for AI.

## The Technical Challenge

Building a WebSocket server in pure Lua with only Neovim built-ins was... interesting:

- Implemented SHA-1 from scratch (needed for WebSocket handshake)
- Built a complete RFC 6455 WebSocket frame parser
- Created base64 encoding/decoding functions
- All using just `vim.loop` and basic Lua

No external dependencies. Just pure, unadulterated Neovim.

## What This Means

This discovery opens doors:

1. **Any editor can integrate** — The protocol is simple and well-defined
2. **Agents can connect** — You could build automation that connects to any IDE with these extensions
3. **The protocol is extensible** — New tools can be added easily
4. **It's educational** — Understanding how these work demystifies AI coding assistants

## Lessons Learned

1. **Curiosity pays off** — That Reddit post led to this entire journey
2. **Tools matter** — AST-grep was instrumental in understanding the code
3. **AI can build AI tools** — We're in a recursive loop of AI development
4. **Open source wins** — By understanding the protocol, we can build for any platform

## What's Next?

The protocol is documented. The implementation is open source. Now it's your turn.

Build integrations for Emacs, Sublime, or your favorite editor. Create agents that leverage IDE access. Extend the protocol with new capabilities.

The genie is out of the bottle, and it speaks WebSocket.

---

_If you found this story interesting, check out the [protocol documentation](./PROTOCOL.md) for implementation details, or dive into the [code](https://github.com/coder/claudecode.nvim) to see how it all works._
