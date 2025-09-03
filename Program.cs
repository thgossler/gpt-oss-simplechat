#region // ========== License ==========
// MIT License
//
// Copyright (c) 2025 Thomas Gossler
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
#endregion

using System.ClientModel;
using Microsoft.Extensions.AI;
using OpenAI;
using OpenAI.Chat;

// LM Studio endpoint (default port is 1234)
var endpoint = new Uri("http://localhost:1234/v1");
var apiKey = "lm-studio"; // dummy string works for LM Studio
var modelId = "openai/gpt-oss-20b";

// Create an OpenAI ChatClient and adapt it to IChatClient
OpenAIClient root = new(new ApiKeyCredential(apiKey), new OpenAIClientOptions { Endpoint = endpoint });
ChatClient openAiChat = root.GetChatClient(modelId);
IChatClient chatClient = openAiChat.AsIChatClient();

var history = new List<Microsoft.Extensions.AI.ChatMessage>
{
    new(Microsoft.Extensions.AI.ChatRole.System,
// System Message
"""
You are a helpful assistant. Keep your answers concise.
""")
};

Console.WriteLine($"Using model '{modelId}' on endpoint '{endpoint}'");
Console.WriteLine("Starting chat...");
Console.WriteLine("Type 'exit' to quit");
Console.WriteLine("Enter your message:");

while (true)
{
    // Read user message
    var input = LineEditor.ReadLine("> ");

    // Check for exit command
    if (string.Equals(input, "exit", StringComparison.OrdinalIgnoreCase))
        break;

    // Add user message to history as prompt input for the AI model
    history.Add(new(Microsoft.Extensions.AI.ChatRole.User, CreateUserMessage(input)));

    // Send history of messages as request to the AI model and stream and render the response
    var assistantText = await StreamAndRenderAsync(openAiChat, history);

    // Add assistant message (response text) to the history
    history.Add(new(Microsoft.Extensions.AI.ChatRole.Assistant, assistantText));
}


#region // ========== Helpers ==========

const string openThought = "<thought>";
const string closeThought = "</thought>";
const string openAnswer = "<answer>";
const string closeAnswer = "</answer>";

static string CreateUserMessage(string input)
{
    return !string.IsNullOrWhiteSpace(input) ?
$"""
Respond in this format:
{openThought}...{closeThought}
{openAnswer}...{closeAnswer}

User input:
{input}
""" : string.Empty;
}

static (List<string> thoughts, List<string> answers) ExtractSections(string responseText)
{
    var thoughts = new List<string>();
    var answers = new List<string>();

    void ExtractTag(string openTag, string closeTag, List<string> sink)
    {
        int idx = 0;
        while (true)
        {
            int start = responseText.IndexOf(openTag, idx, StringComparison.OrdinalIgnoreCase);
            if (start == -1) break;
            int end = responseText.IndexOf(closeTag, start, StringComparison.OrdinalIgnoreCase);
            if (end == -1) break;
            var content = responseText.Substring(start + openTag.Length, end - (start + openTag.Length)).Trim();
            if (!string.Equals(content, "...")) sink.Add(content);
            idx = end + closeTag.Length;
        }
    }

    ExtractTag(openThought, closeThought, thoughts);
    ExtractTag(openAnswer, closeAnswer, answers);

    return (thoughts, answers);
}

static IEnumerable<OpenAI.Chat.ChatMessage> ConvertToOpenAiMessages(List<Microsoft.Extensions.AI.ChatMessage> history)
{
    foreach (var m in history)
    {
        var text = m.Text ?? string.Empty;
        if (m.Role == Microsoft.Extensions.AI.ChatRole.System)
            yield return new OpenAI.Chat.SystemChatMessage(text);
        else if (m.Role == Microsoft.Extensions.AI.ChatRole.User)
            yield return new OpenAI.Chat.UserChatMessage(text);
        else if (m.Role == Microsoft.Extensions.AI.ChatRole.Assistant)
            yield return new OpenAI.Chat.AssistantChatMessage(text);
        else
            yield return new OpenAI.Chat.UserChatMessage(text);
    }
}

static string? ExtractTextDelta(object update)
{
    // Try known OpenAI .NET streaming update shapes reflectively to avoid hard dependency on exact types
    // 1) update has a property ContentUpdate: IEnumerable where elements may be TextContent with Text
    var updateType = update.GetType();
    var contentUpdateProp = updateType.GetProperty("ContentUpdate");
    if (contentUpdateProp != null)
    {
        var contentUpdate = contentUpdateProp.GetValue(update) as System.Collections.IEnumerable;
        if (contentUpdate != null)
        {
            var sb = new System.Text.StringBuilder();
            foreach (var part in contentUpdate)
            {
                var partType = part.GetType();
                var kindProp = partType.GetProperty("Kind");
                var textProp = partType.GetProperty("Text");
                if (textProp != null)
                {
                    var textVal = textProp.GetValue(part) as string;
                    if (!string.IsNullOrEmpty(textVal)) sb.Append(textVal);
                }
            }
            var val = sb.ToString();
            if (!string.IsNullOrEmpty(val)) return val;
        }
    }

    // 2) update has a TextDelta or Text property
    var textDeltaProp = updateType.GetProperty("TextDelta") ?? updateType.GetProperty("Text");
    if (textDeltaProp != null)
    {
        var txt = textDeltaProp.GetValue(update) as string;
        if (!string.IsNullOrEmpty(txt)) return txt;
    }

    return null;
}

static async Task<string> StreamAndRenderAsync(ChatClient openAiChat, List<Microsoft.Extensions.AI.ChatMessage> history)
{
    // Aggregate full text to return for history
    var aggregated = new System.Text.StringBuilder();

    // Pending buffer for incremental parsing across chunk boundaries
    var pending = new System.Text.StringBuilder();

    // Streaming state
    TagState state = TagState.Outside;

    // Ephemeral thought rendering (single updating line)
    var thoughtSoFar = new System.Text.StringBuilder();
    int thoughtRenderLen = 0;
    bool showingThought = false;
    bool answerStarted = false;
    int answerCharsWritten = 0; // tracks printed answer characters (for newline decisions)
    bool answerClosed = false;  // tracks if we emitted the closing newline for <answer>

    void RenderThoughtEphemeral()
    {
        // Render thought on a single line, updating in place; replace newlines
        var text = thoughtSoFar.ToString().Replace('\r', ' ').Replace('\n', ' ').TrimStart();
        Console.ForegroundColor = ConsoleColor.DarkGray;
        Console.Write('\r');
        Console.Write(text);
        int extra = Math.Max(0, thoughtRenderLen - text.Length);
        if (extra > 0) Console.Write(new string(' ', extra));
        thoughtRenderLen = text.Length;
        Console.ResetColor();
    }

    void ClearThoughtEphemeral()
    {
        if (!showingThought && thoughtRenderLen == 0) return;
        Console.Write('\r');
        if (thoughtRenderLen > 0) Console.Write(new string(' ', thoughtRenderLen));
        Console.Write('\r');
        thoughtRenderLen = 0;
        showingThought = false;
        thoughtSoFar.Clear();
    }

    // Helper: process as much as possible from pending buffer
    void ProcessPending()
    {
        while (true)
        {
            if (state == TagState.Outside)
            {
                var s = pending.ToString();
                int idxT = s.IndexOf(openThought, StringComparison.OrdinalIgnoreCase);
                int idxA = s.IndexOf(openAnswer, StringComparison.OrdinalIgnoreCase);
                if (idxT == -1 && idxA == -1)
                {
                    // Keep only a small tail to catch split tags across chunks
                    int keep = Math.Max(openThought.Length, openAnswer.Length) - 1;
                    if (pending.Length > keep)
                    {
                        pending.Remove(0, pending.Length - keep);
                    }
                    break;
                }

                int nextIdx;
                bool isThought;
                if (idxT == -1) { nextIdx = idxA; isThought = false; }
                else if (idxA == -1) { nextIdx = idxT; isThought = true; }
                else if (idxT < idxA) { nextIdx = idxT; isThought = true; }
                else { nextIdx = idxA; isThought = false; }

                // Drop any text before the next start tag (omit untagged text)
                if (nextIdx > 0) pending.Remove(0, nextIdx);

                // Consume the opening tag and switch state
                if (isThought)
                {
                    if (pending.Length >= openThought.Length)
                    {
                        pending.Remove(0, openThought.Length);
                        state = TagState.InThought;
                        showingThought = true;
                        // Start rendering immediately (even if empty)
                        RenderThoughtEphemeral();
                    }
                    else
                    {
                        // Wait for more chars of the opening tag
                        break;
                    }
                }
                else
                {
                    if (pending.Length >= openAnswer.Length)
                    {
                        pending.Remove(0, openAnswer.Length);
                        // When answer starts, clear any ephemeral thought
                        if (showingThought)
                        {
                            ClearThoughtEphemeral();
                        }
                        state = TagState.InAnswer;
                        answerStarted = true;
                        answerClosed = false;
                    }
                    else
                    {
                        break; // incomplete tag, wait for more
                    }
                }
            }
            else if (state == TagState.InThought)
            {
                var s = pending.ToString();
                int closeIdx = s.IndexOf(closeThought, StringComparison.OrdinalIgnoreCase);
                if (closeIdx != -1)
                {
                    // Append up to the closing tag and render; then consume close tag
                    if (closeIdx > 0)
                    {
                        thoughtSoFar.Append(s.AsSpan(0, closeIdx).ToString());
                        RenderThoughtEphemeral();
                    }
                    pending.Remove(0, closeIdx + closeThought.Length);
                    state = TagState.Outside;
                }
                else
                {
                    // Stream partial content but keep a small tail to detect the closing tag across chunks
                    int safeLen = Math.Max(0, pending.Length - (closeThought.Length - 1));
                    if (safeLen > 0)
                    {
                        thoughtSoFar.Append(pending.ToString(0, safeLen));
                        pending.Remove(0, safeLen);
                        RenderThoughtEphemeral();
                    }
                    break; // wait for more
                }
            }
            else // InAnswer
            {
                var s = pending.ToString();
                int closeIdx = s.IndexOf(closeAnswer, StringComparison.OrdinalIgnoreCase);
                if (closeIdx != -1)
                {
                    if (closeIdx > 0)
                    {
                        var chunk = s.AsSpan(0, closeIdx).ToString();
                        Console.Write(chunk);
                        answerCharsWritten += chunk.Length;
                    }
                    pending.Remove(0, closeIdx + closeAnswer.Length);
                    state = TagState.Outside;
                    Console.WriteLine(); // end the answer line
                    answerClosed = true;
                }
                else
                {
                    int safeLen = Math.Max(0, pending.Length - (closeAnswer.Length - 1));
                    if (safeLen > 0)
                    {
                        var chunk = pending.ToString(0, safeLen);
                        Console.Write(chunk);
                        answerCharsWritten += chunk.Length;
                        pending.Remove(0, safeLen);
                    }
                    break; // wait for more
                }
            }
        }
    }

    var oaMessages = ConvertToOpenAiMessages(history);

    await foreach (var update in openAiChat.CompleteChatStreamingAsync(oaMessages))
    {
        var deltaText = ExtractTextDelta(update);
        if (string.IsNullOrEmpty(deltaText)) continue;

        aggregated.Append(deltaText);
        pending.Append(deltaText);
        ProcessPending();
    }

    // Stream finished:
    // 1) Always clear any ephemeral thought line so it doesn't remain visible
    if (showingThought)
    {
        ClearThoughtEphemeral();
    }

    // 2) If the stream ended while still inside an <answer> without emitting a newline,
    //    ensure we end the line exactly once so the next prompt starts on a new line
    if (state == TagState.InAnswer && answerCharsWritten > 0 && !answerClosed)
    {
        Console.WriteLine();
        answerClosed = true;
    }

    // 3) If no answer was streamed, try a non-stream fallback: parse the aggregated
    //    text and print only the <answer> content (keeping thoughts hidden)
    if (!answerStarted)
    {
        var (_, answers) = ExtractSections(aggregated.ToString());
        foreach (var a in answers)
        {
            Console.WriteLine(a);
        }
    }

    return aggregated.ToString();
}

static class LineEditor
{
    // Simple in-memory history shared across prompts
    private static readonly List<string> s_history = new();
    private static int s_historyPos = -1; // -1 means editing a new entry

    public static string ReadLine(string prompt)
    {
        // Capture base position, write prompt, and remember we render from base
        int baseLeft = Console.CursorLeft;
        int baseTop = Console.CursorTop;
        Console.Write(prompt);

        var buffer = new List<char>(128);
        int cursor = 0; // index within buffer
        int lastRenderLen = 0; // prompt + buffer length from last render
        string historyOriginal = string.Empty; // the text that was present before navigating history

        void Render()
        {
            int width = Math.Max(1, Console.BufferWidth);
            // Move to start
            Console.SetCursorPosition(baseLeft, baseTop);
            // Write current line content
            string content = new string(buffer.ToArray());
            string full = prompt + content;
            Console.Write(full);
            // Clear any leftover characters from previous longer render
            int extra = Math.Max(0, lastRenderLen - full.Length);
            if (extra > 0) Console.Write(new string(' ', extra));

            // Compute and set cursor back to logical position
            int absolute = prompt.Length + cursor; // offset from base (including prompt)
            int targetTop = baseTop + ((baseLeft + absolute) / width);
            int targetLeft = (baseLeft + absolute) % width;
            try { Console.SetCursorPosition(targetLeft, targetTop); } catch { /* ignore out of range */ }

            lastRenderLen = full.Length;
        }

        static bool IsWordChar(char ch) => char.IsLetterOrDigit(ch) || ch == '_';

        void MovePrevWord()
        {
            if (cursor == 0) return;
            int i = cursor - 1;
            // Skip any spaces/punct left of cursor
            while (i > 0 && !IsWordChar(buffer[i])) i--;
            // Move across the word
            while (i > 0 && IsWordChar(buffer[i - 1])) i--;
            cursor = i;
        }

        void MoveNextWord()
        {
            if (cursor >= buffer.Count) return;
            int i = cursor;
            // Skip current word if in one
            while (i < buffer.Count && IsWordChar(buffer[i])) i++;
            // Skip delimiters until next word start
            while (i < buffer.Count && !IsWordChar(buffer[i])) i++;
            cursor = i;
        }

        while (true)
        {
            var key = Console.ReadKey(intercept: true);

            if (key.Key == ConsoleKey.Enter)
            {
                // Move cursor to end, print newline, and finish
                cursor = buffer.Count;
                Render();
                Console.WriteLine();
                var text = new string(buffer.ToArray());
                if (!string.IsNullOrWhiteSpace(text))
                {
                    if (s_history.Count == 0 || !string.Equals(s_history[^1], text, StringComparison.Ordinal))
                        s_history.Add(text);
                }
                s_historyPos = -1;
                return text;
            }
            else if (key.Key == ConsoleKey.LeftArrow)
            {
                if (cursor > 0) cursor--;
                Render();
            }
            else if (key.Key == ConsoleKey.RightArrow)
            {
                if (cursor < buffer.Count) cursor++;
                Render();
            }
            else if (key.Key == ConsoleKey.UpArrow)
            {
                if (s_history.Count > 0)
                {
                    if (s_historyPos == -1)
                    {
                        historyOriginal = new string(buffer.ToArray());
                        s_historyPos = s_history.Count - 1;
                    }
                    else if (s_historyPos > 0)
                    {
                        s_historyPos--;
                    }
                    buffer.Clear();
                    buffer.AddRange(s_history[s_historyPos]);
                    cursor = buffer.Count;
                    Render();
                }
            }
            else if (key.Key == ConsoleKey.DownArrow)
            {
                if (s_historyPos >= 0)
                {
                    if (s_historyPos < s_history.Count - 1)
                    {
                        s_historyPos++;
                        buffer.Clear();
                        buffer.AddRange(s_history[s_historyPos]);
                    }
                    else
                    {
                        // Move back to editing a new entry, restore original
                        s_historyPos = -1;
                        buffer.Clear();
                        buffer.AddRange(historyOriginal);
                    }
                    cursor = buffer.Count;
                    Render();
                }
            }
            else if (key.Key == ConsoleKey.Home)
            {
                cursor = 0;
                Render();
            }
            else if (key.Key == ConsoleKey.End)
            {
                cursor = buffer.Count;
                Render();
            }
            else if (key.Key == ConsoleKey.Backspace)
            {
                if (cursor > 0)
                {
                    buffer.RemoveAt(cursor - 1);
                    cursor--;
                    Render();
                }
            }
            else if (key.Key == ConsoleKey.Delete)
            {
                if (cursor < buffer.Count)
                {
                    buffer.RemoveAt(cursor);
                    Render();
                }
            }
            else if (key.Key == ConsoleKey.Escape)
            {
                // Clear line
                buffer.Clear();
                cursor = 0;
                Render();
            }
            else if (key.Modifiers == ConsoleModifiers.Control && (key.Key == ConsoleKey.A || key.Key == ConsoleKey.E))
            {
                // Common shortcuts: Ctrl+A -> start, Ctrl+E -> end
                cursor = key.Key == ConsoleKey.A ? 0 : buffer.Count;
                Render();
            }
            else if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.LeftArrow)
            {
                MovePrevWord();
                Render();
            }
            else if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.RightArrow)
            {
                MoveNextWord();
                Render();
            }
            else
            {
                // Insert printable character(s)
                char c = key.KeyChar;
                if (!char.IsControl(c))
                {
                    buffer.Insert(cursor, c);
                    cursor++;
                    Render();
                }
            }
        }
    }
}

enum TagState
{
    Outside,
    InThought,
    InAnswer
}

#endregion
