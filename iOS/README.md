# DynamicWall for iPhone

A fresh wallpaper on your iPhone every day, from Bing or Windows Spotlight. The iPhone version of [DynamicWall for Mac](../README.md).

## Features

- **Daily Bing picture** from 13 regions, and **daily Windows Spotlight picture**
- **Previous / Next** through the last 8 days of Bing, or your earlier Spotlight pictures
- **Gallery** of recent pictures
- **Always 4K:** every picture is downloaded in 4K and cropped to your screen around its most interesting part, or you choose with **Zoom & Select**
- **Set as Wallpaper** in one tap, plus an automatic new wallpaper every morning
- **Widgets:** Picture of the Day, Up Next (tomorrow's Spotlight picture), Browse with ‹ › buttons, Favorites, and a Lock Screen widget with today's place
- **Swipe** left and right, and **♥ Favorites**
- Save to Photos and share
- No ads, no tracking, no account

## How the wallpaper changes

Apple doesn't let iPhone apps change the wallpaper themselves. DynamicWall adds a **Get DynamicWall Picture** action to Apple's Shortcuts app instead:

1. Make a shortcut called **DynamicWall** with two actions: **Get DynamicWall Picture**, then **Set Wallpaper Photo** (turn off *Show Preview* and *Crop to Subject*).
2. In Shortcuts → **Automation**, add a **Time of Day** automation (for example 8:00 AM, daily, *Run Immediately*) that runs it.

The app walks you through this the first time you tap **Set as Wallpaper**. After that, the button applies the picture you're looking at, and the automation changes it every morning.

## Run it on your iPhone

You need a Mac with Xcode 15 or later. A free Apple ID is enough.

1. Open `DynamicWall.xcodeproj` in Xcode.
2. Click the project, then for **both** targets (*DynamicWall* and *DynamicWallWidget*) open **Signing & Capabilities** and choose your **Team** (your Apple ID; add it in Xcode → Settings → Accounts if needed).
   If Xcode says the bundle identifier isn't available, change `com.shantanukhedar.dynamicwall.ios` to something unique in both targets, keeping `.widget` at the end of the widget's.
3. Connect your iPhone with a cable, select it at the top of Xcode, and press **Run** (⌘R).
4. On the iPhone, the first time:
   - Turn on **Settings → Privacy & Security → Developer Mode** and restart when asked.
   - With a free Apple ID, also trust yourself: **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.

With a free Apple ID the app stops opening after 7 days; just press Run in Xcode again. With the paid Apple Developer Program it lasts a year, and you can share it with friends through TestFlight.

## App Store notes

Before submitting to the App Store:

- **Tips:** Apple requires tips inside iPhone apps to use In-App Purchase, so the PayPal links on the *Say Thank You* screen must be removed or replaced with In-App Purchase tips (guideline 3.1.1).
- **Content:** the Bing and Spotlight feeds are unofficial and the pictures belong to Microsoft's licensors, so App Review may reject the app under guideline 5.2.

Neither applies when you run it yourself from Xcode.

## Privacy

DynamicWall collects no data. It connects only to Microsoft's Bing and Windows Spotlight servers, over HTTPS, to download pictures, and only saves to your photo library when you tap **Save**.

## Disclaimer

DynamicWall is an independent project and is not affiliated with Microsoft. Bing and Windows Spotlight are trademarks of Microsoft. Pictures are copyright of their respective owners, for personal wallpaper use only.
