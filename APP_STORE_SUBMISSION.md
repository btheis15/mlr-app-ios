# MLR App — App Store Connect submission checklist

Copy-paste reference for the first submission (v1.0). Bundle `com.muskellungelakeresort.mlr`,
team `UBM722BP54`.

---

## 0. Do these first (outside App Store Connect)

- [ ] **Xcode** — MLR App target → Build Settings → **+** → Add User-Defined Setting:
      `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` = `NO`
- [ ] **Mac mini** — commit/push `~/Repos/mlr-app`, then on the mini:
      `git pull && launchctl kickstart -k gui/$(id -u)/com.mlr.media-server`
      (activates the `/privacy` page + the reviewer-account push guard)
- [ ] Confirm privacy page loads: open `<PUBLIC_URL>/privacy` in a browser
- [ ] Supabase review account exists + confirmed (already done): verify query shows
      `App Review / include_in_directory=false / confirmed=true`

---

## 1. Create the app record

App Store Connect → My Apps → **+** → New App
- Platform: iOS
- Name: **Muskellunge Lake Resort**  *(must be unique on the store; fallbacks: "Muskellunge Lake Resort — Family", "MLR Family")*
- Primary language: English (U.S.)
- Bundle ID: `com.muskellungelakeresort.mlr`
- SKU: `MLR-IOS-001`
- User access: Full Access

---

## 2. Pricing & Availability

- [ ] Price: **Free**
- [ ] Availability: **United States, Canada, Mexico** only
      (this removes the DSA / Vietnam / Regulated-Devices requirements)

---

## 3. App Privacy

**"Do you or your third-party partners collect data from this app?" → Yes**

For EVERY type below: **Linked to identity = Yes**, **Used for tracking = No**, **Purpose = App Functionality**.

| Category | Type |
|---|---|
| Contact Info | Name |
| Contact Info | Email Address |
| Contact Info | Phone Number |
| Contact Info | Physical Address |
| User Content | Photos or Videos |
| User Content | Other User Content |
| Identifiers | User ID |
| Identifiers | Device ID |

Do NOT declare: Location, Health, Contacts, Financial Info, Browsing/Search History,
Purchases, Usage Data, Diagnostics. (Payment handles are just usernames → covered by
"Other User Content"; the app has no Apple in-app purchases.)

- [ ] Privacy Policy URL: `https://brians-mac-mini.tail49943c.ts.net/privacy`  (verified live, 200 OK)

---

## 4. App Information

- [ ] Category: **Primary = Social Networking** (secondary: Lifestyle, optional)
- [ ] Content Rights: does not use third-party content
- [ ] Age Rating: answer all "None/No" → should yield **4+**

---

## 5. Version metadata (1.0)

**Subtitle (≤30):**
```
Your family lake community
```

**Promotional text (≤170):**
```
Stay connected with everyone Up North — events, chat, help requests, cabin bookings, and Family Fest, all in one place.
```

**Description:**
```
Muskellunge Lake Resort brings the whole family together in one private app. See what's happening, pitch in, and stay in touch year-round.

• Family Feed — share photos and updates
• Events & RSVPs — never miss a gathering
• Chat — group and committee conversations
• Ask for Help — rally hands when you need them
• Work Checklist — keep the resort running
• Cabin Bookings — request and manage stays
• People Directory — find and connect with family
• Family Fest — schedule, dinners, and photos

Private to Muskellunge Lake Resort members.
```

**Keywords (≤100):**
```
lake,resort,family,community,cabin,events,rsvp,chat,directory,muskellunge
```

**Support URL:** _________________  *(a reachable page; if you have no resort site, `https://brians-mac-mini.tail49943c.ts.net/privacy` is accepted)*
**Marketing URL (optional):** _________________
**Copyright:** `2026 Muskellunge Lake Resort`

---

## 6. Screenshots

Upload from the repo (exact required sizes, no resizing needed):
- **iPhone 6.9"** → `screenshots/iphone/` (1320×2868): Home, Family Fest, Activity, Profile, Events
- **iPad 13"** → `screenshots/ipad/` (2064×2752): Home, Family Fest, Activity, Profile, Events

Do NOT upload the files in `screenshots/iphone/excluded-has-personal-info/` (real names/phone numbers).

---

## 7. App Review Information

Enable **Sign-In Required**.
- **User name:** `appreview@muskellungelakeresort.com`
- **Password:** `77341902`

**Notes:**
```
This is a private, invite-only community app for members of Muskellunge Lake Resort. Sign-in normally uses an emailed one-time code, which a reviewer cannot receive. For review, enter the email and code above: on the "Enter your code" screen, type 77341902 to sign in. No real code is emailed. The app is intended only for family members of the resort.
```

- [ ] Contact info: your name, phone, email

---

## 8. Export compliance

When asked "Does your app use encryption?" → the `ITSAppUsesNonExemptEncryption = NO` key
(step 0) auto-answers this. If prompted anyway: Yes (HTTPS) → qualifies for exemption →
no documentation / no annual report.

---

## 9. Build → submit

- [ ] Xcode: run destination = **Any iOS Device (arm64)** → **Product → Archive**
- [ ] Organizer → **Distribute App → App Store Connect** → Upload
- [ ] Wait for the build to finish processing (email confirms), then attach it to the 1.0 version
- [ ] (Optional) TestFlight self-test with the review account
- [ ] **Add for Review → Submit**

---

## Reference — reviewer bypass internals (for future you)

- Code: `ReviewAccess` in `MLRApp/Auth/AuthService.swift`. Review email skips the real OTP
  email and, on code `77341902`, signs in with embedded password `Mlr!Review-2026-x9Kp3qL`.
- Hidden from the People directory (`PeopleDirectoryView` filter) and from the new-member
  alert (migration `0073` + `push-sender.js` guard).
- **After approval:** rotate/delete the review account + the constants, or leave it — your call.
```
```
