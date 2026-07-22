import Foundation

/// How token accounting actually works across the providers Agamemnon monitors.
///
/// Every suggestion cites one of these entries so a finding explains the mechanism
/// rather than just asserting a number. Bundled and offline: the app makes no network
/// requests, so this is maintained here rather than fetched.
public struct KnowledgeEntry: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var provider: String
    public var summary: String
    /// What to actually do about it.
    public var practice: String

    public init(id: String, title: String, provider: String, summary: String, practice: String) {
        self.id = id
        self.title = title
        self.provider = provider
        self.summary = summary
        self.practice = practice
    }
}

public enum KnowledgeBase {
    public static let entries: [KnowledgeEntry] = [
        KnowledgeEntry(
            id: "cache-prefix",
            title: "Prompt caching is a prefix match",
            provider: "Anthropic",
            summary: """
            The cache key is the exact bytes of the rendered prompt up to each breakpoint, \
            in the order tools, then system, then messages. A single byte that changes \
            anywhere in the prefix invalidates every cached block after it. A timestamp, a \
            request id, a re-ordered JSON key, or a tool list that varies per run will \
            silently drop the hit rate to zero while the request still succeeds.
            """,
            practice: """
            Keep the system prompt and tool list byte-stable across a session. Put anything \
            volatile after the last cache breakpoint. If cache reads are near zero across \
            repeated similar requests, something in the prefix is changing per call.
            """
        ),
        KnowledgeEntry(
            id: "cache-economics",
            title: "Cache reads cost 0.1x, writes cost 1.25x or 2x",
            provider: "Anthropic",
            summary: """
            A token served from cache bills at one tenth the base input rate. Writing to the \
            5-minute cache costs 1.25x, and to the 1-hour cache 2x. Break-even on a 5-minute \
            write is two requests; a 1-hour write needs at least three reads before it pays \
            for itself.
            """,
            practice: """
            The 1-hour TTL is worth its doubled write cost only when gaps between requests \
            regularly exceed five minutes. For continuous work the 5-minute cache is cheaper. \
            Paying the 1-hour premium on a session that never idles is pure loss.
            """
        ),
        KnowledgeEntry(
            id: "cache-min-prefix",
            title: "Short prefixes silently refuse to cache",
            provider: "Anthropic",
            summary: """
            The minimum cacheable prefix is model dependent: 4096 tokens on the Opus family \
            and Haiku 4.5, 2048 on Sonnet 4.6, 1024 on older Sonnet. Below that a cache \
            breakpoint is accepted and simply does nothing, reporting zero cache creation \
            with no error.
            """,
            practice: """
            A prompt around 3K tokens caches on Sonnet 4.5 but not on Opus 4.8. If cache \
            creation reads zero on a small prompt, the prefix is under the model's floor \
            rather than misconfigured.
            """
        ),
        KnowledgeEntry(
            id: "effort",
            title: "Effort is the main cost lever on current models",
            provider: "Anthropic",
            summary: """
            On Opus 4.7 and later, output_config.effort controls both thinking depth and how \
            many tool calls a turn makes. Higher effort means more exploration and more \
            tokens; lower effort scopes work to what was literally asked. The default is high.
            """,
            practice: """
            Reserve xhigh and max for genuinely hard agentic and coding work. Routine edits, \
            lookups and classification run well at low or medium, often at a fraction of the \
            tokens. On long agentic runs, higher effort can reduce total cost by cutting turn \
            count even though each turn is more expensive.
            """
        ),
        KnowledgeEntry(
            id: "windows",
            title: "Subscription windows are session blocks, not sliding windows",
            provider: "Anthropic",
            summary: """
            A Claude subscription meters usage in a fixed five-hour block that starts at the \
            first message after the previous block expired, plus a separate weekly cap. The \
            block does not slide with the clock, which is why the CLI reports a specific \
            reset time rather than a countdown.
            """,
            practice: """
            Starting a heavy run late in a block wastes the remainder of the next one. \
            Check the reset time before beginning long work, and prefer to start a big job \
            just after a block turns over.
            """
        ),
        KnowledgeEntry(
            id: "context-growth",
            title: "Cost per turn grows with conversation length",
            provider: "General",
            summary: """
            The API is stateless, so the whole conversation is resent on every turn. Even \
            fully cached, a long session pays the cache-read rate on the entire history each \
            time. Cost per turn therefore rises roughly linearly with session length, which \
            is why a few long sessions can outspend many short ones doing the same work.
            """,
            practice: """
            Split unrelated work into separate sessions rather than continuing one. Use \
            compaction or context editing on genuinely long-running agents so old tool \
            results stop being resent.
            """
        ),
        KnowledgeEntry(
            id: "provider-cache",
            title: "Cache semantics differ by provider",
            provider: "Cross-provider",
            summary: """
            OpenAI caches automatically with no explicit breakpoints and reports a single \
            cached_input_tokens figure at roughly 0.1x. Gemini distinguishes implicit from \
            explicit context caching, the latter billed for storage duration. Kimi reports \
            cache read and creation separately, like Anthropic, but without a TTL split. \
            Cursor exposes no token accounting locally at all.
            """,
            practice: """
            Do not compare raw cached-token counts across providers as if they meant the \
            same thing. Compare cost, or input-token-equivalents, which is what this app's \
            window bars track.
            """
        ),
    ]

    public static func entry(_ id: String) -> KnowledgeEntry? {
        entries.first { $0.id == id }
    }
}
