# gpt-oss-simplechat

A tiny .NET console app that chats with a local LLM via LM Studio using the OpenAI-compatible API and Microsoft.Extensions.AI adapters. It streams responses and separates internal thoughts from the final answer.

## Requirements

- .NET 9 SDK
- LM Studio (or any OpenAI-compatible server) running locally
  - Default endpoint used in this app: http://localhost:1234/v1
  - Dummy API key is accepted by LM Studio: "lm-studio"

## Dependencies

This project uses the following NuGet packages (resolved via the csproj):
- Microsoft.Extensions.AI
- Microsoft.Extensions.AI.OpenAI
- OpenAI (Azure SDK client for OpenAI-compatible APIs)
- System.ClientModel

These assemblies appear in `bin/Debug/net9.0/` after build.

## How it works

- `Program.cs` constructs an OpenAI chat client pointed at the local endpoint and adapts it to `IChatClient`.
- User input is sent along with a small system prompt that asks the model to respond with <thought> and <answer> sections.
- Streaming deltas are parsed; only complete tagged sections are printed.

## Configure model and endpoint

Change these variables in `Program.cs` to match your local setup:
- `endpoint`: URI to your OpenAI-compatible server (LM Studio default is `http://localhost:1234/v1`).
- `apiKey`: For LM Studio, any non-empty string works (e.g. `"lm-studio"`).
- `modelId`: The model name exposed by your server (e.g. `openai/gpt-oss-20b`).

## Build

If you're using VS Code, a build task is provided. From the terminal:

```bash
dotnet build
```

## Run

Run the produced app (adjust path if using Release):

```bash
dotnet run
```

or

```bash
./bin/Debug/net9.0/gpt-oss-test
```

## Notes

- Make sure your local server is running and the model is loaded before starting the app, otherwise requests will fail.
- If your server requires a real API key, set `apiKey` accordingly or use an environment variable wiring as needed.

## Install LM Studio and the model

This repo provides helper scripts to install prerequisites and prepare LM Studio with the `gpt-oss-20b` model.

- On Linux or macOS: run `./install.sh` (ensures PowerShell 7, then calls the PowerShell installer)
- Alternatively, on macOS/Windows: run `pwsh -File ./install.ps1`

Hardware note: The `gpt-oss-20b` model requires more than 16 GB GPU VRAM. On Apple Silicon (Unified Memory), this means more than 16 GB system RAM.

What the installer does:

1) Installs LM Studio if missing
  - macOS: `brew install --cask lm-studio`
  - Windows: `winget install --id ElementLabs.LMStudio -e`
  - Linux: prompts to download the AppImage from https://lmstudio.ai/download

2) Ensures .NET 9 SDK is installed (winget/brew/dotnet-install)

3) Boots the `lms` CLI, starts the local server, and pulls the model
  - Starts LM Studio local server on port 1234
  - Downloads and loads `openai/gpt-oss-20b` (or a custom `-Model` argument)

Examples:

```bash
# Linux
chmod +x ./install.sh
./install.sh
```

```pwsh
# macOS or Windows
pwsh -File ./install.ps1
```

Choose a different model:

```pwsh
pwsh -File ./install.ps1 -Model "mlx-community/pixtral-12b-4bit"
```

After the script completes, LM Studio’s OpenAI-compatible API should be available at:
http://localhost:1234/v1/

Then run the app:

```bash
dotnet run
```

## License

This project is licensed under the MIT License. See `LICENSE.txt` for details.
