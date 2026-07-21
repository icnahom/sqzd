# sqzd (squeezed)

> 🍋 **Why "sqzd"?**. Just like squeezing a piece of fruit to get the pure juice while leaving the rind behind, sqzd takes bloated videos and extracts only the concentrated, high-value information 


https://github.com/user-attachments/assets/5a4439b4-ed05-4a95-9427-307af734a32e


**sqzd** is a hands-free YouTube wrapper that extracts high-signal moments from long videos. Instead of reading long summaries or manually scrubbing through timelines, sqzd does the work for you—automatically skipping the filler so you can watch just the gold.

## ✨ Features

*   **⏭️ Auto-Skip Video Filler:** No manual clicking required. The app automatically skips intros, outros, sponsor segments, and repetitive tangents, jumping directly to the core takeaways.
*   **🎙️ Voice-Guided Transitions:** A natural Text-to-Speech voice announces the topic of each upcoming segment before it plays, letting you stay informed without needing to look at your screen.
*   **🎧 Background Audio Support:** Listen to your filtered highlights with your screen turned off or while using other applications, integrated directly with your device's native media controls.
*   **📲 Quick-Share Support:** Share any video link directly from the official YouTube app to sqzd to start processing it instantly.

## 🚀 Getting Started

If you are new to Flutter, follow these simplified steps to run sqzd on your machine:

### Step 1: Install Flutter
You need the Flutter SDK installed on your computer to build this app.
*   **[Install Flutter (Official Guide)](https://docs.flutter.dev/get-started/install)** (Select your Operating System: Windows, macOS, or Linux).

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

We do not use unofficial web-scraping tricks to fetch video transcripts. Instead, we use Google's official [Gemini Video Understanding API](https://ai.google.dev/gemini-api/docs/video-understanding#youtube) to analyze the actual video. 

> [!NOTE]
> Because the AI model analyzes the video content directly, initial generation can
> take some time.  We hope to transition to an official, fast YouTube Transcript API
> whenever one becomes publicly available.


## ⚖️ License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

You are free to copy, modify, and distribute this software under the terms of the AGPL-3.0. Please note that if you modify this app and distribute it, you must make your modified source code publicly available under the exact same AGPL-3.0 license.

For complete terms and conditions, please refer to the [LICENSE](LICENSE) file in the repository.
```