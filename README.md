# sqzd (squeezed)

> 🍋 **Why "sqzd"?**. Just like squeezing a piece of fruit to get the pure juice while leaving the rind behind, sqzd takes bloated videos and extracts only the concentrated, high-value information 


https://github.com/user-attachments/assets/5a4439b4-ed05-4a95-9427-307af734a32e


**sqzd** is a hands-free YouTube wrapper that extracts high-signal moments from long videos. Instead of reading long summaries or manually scrubbing through timelines, sqzd does the work for you—automatically skipping the filler so you can watch just the gold.

## ✨ Features

* **⏭️ Auto-Skip:** No manual clicking required. The app automatically jumps to the core takeaways.
* **🎙️ Voice-Guided:** A natural voice announces the topic, letting you stay informed without needing to look at your screen.
* **🎧 Background Audio:** Keep listening with your screen off, fully integrated with native media controls.
* **📲 Quick-Share:** Send links directly from the official YouTube app to start processing instantly.

## 📥 Download & Install

### Android

* **Direct APK:** Download the latest compiled `app-release.apk` directly from our [Releases](https://github.com/icnahom/sqzd/releases/latest) page.

### iOS

* **AltStore:** Sideload easily without a computer by adding our custom source to your [AltStore](https://altstore.io) app. Tap `+` in the Sources tab and paste this URL:
```text
https://raw.githubusercontent.com/icnahom/sqzd/main/app.json
```


* **Direct IPA:** Download the unsigned `app.ipa` from our [Releases](https://github.com/icnahom/sqzd/releases/latest) page for manual sideloading.

## 🛠️ Build from Source

If you want to contribute or modify the codebase, follow these simplified steps to compile and run sqzd on your machine:

### Step 1: Install Flutter

You need the Flutter SDK installed on your computer to build this app.

* **[Install Flutter (Official Guide)](https://docs.flutter.dev/get-started/install)** (Select your Operating System: Windows, macOS, or Linux).

### Step 2: Download the Code

Open your computer's terminal (or command prompt) and run these commands to clone the code and enter the project folder:

```bash
git clone https://github.com/yourusername/sqzd.git
cd sqzd

```

### Step 3: Fetch Packages

Run this command to download the software libraries the app needs to run:

```bash
flutter pub get

```

### Step 4: Run the App

Connect your phone via USB (with Developer Mode enabled) or open a virtual device emulator, then run:

```bash
flutter run --profile

```

## 🧠 How It Works

We do not use unofficial web-scraping tricks to fetch video transcripts. Instead, we use the official [Gemini Video Understanding API](https://ai.google.dev/gemini-api/docs/video-understanding#youtube) using the `fileUri` method with the YouTube video URL.

> [!NOTE]
> Because the AI model analyzes the video content directly, initial generation can take some time. We hope to transition to an official, 
> fast YouTube Transcript API whenever one becomes publicly available.

## 📁 Why a single `main.dart`?

You might notice the entire app lives in one file — `lib/main.dart`. This is intentional.

- **🧑‍💻 Optimized for AI agents.** This codebase is designed to be read, understood, and edited by AI coding agents. A single file means the agent gets the full picture in one shot.
- **🪙 Input tokens are cheap.** Throwing a ~20k token file at an LLM costs pennies. There's no need to split things up just to save on token cost.
- **📦 Context windows are big.** Modern models comfortably handle 100k+ tokens. In a world of 1M context windows, the codebase can be the memory.

> [!NOTE]
> Since the agent has full context, we can split into multiple files anytime. The single file stays until there's a concrete reason to split.

## ⚖️ License

This project is licensed under the **PolyForm Noncommercial License 1.0.0**. 

You are free to view, fork, modify, and use this software for personal, educational, 
and non-commercial purposes. **Commercial use, including publishing this application 
to any app store for profit, or using it within a commercial business, is strictly prohibited.**

For commercial licensing inquiries, please contact me directly.
