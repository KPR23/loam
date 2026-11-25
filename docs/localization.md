# Localization

Loam ships in English (the source language) and Polish. Every user-facing string lives in a
String Catalog, so a new language is a new column in the catalog, not a code change.

## Where strings live

- `Loam/Resources/Localizable.xcstrings`: everything the app shows, plus App Intent titles,
  descriptions and Siri dialogs.
- `Loam/Resources/InfoPlist.xcstrings`: permission prompts from `Info.plist`.

`SWIFT_EMIT_LOC_STRINGS` is on, so Xcode adds each new string to the catalog when it builds.

## Writing translatable code

- `Text("…")`, `Button("…")`, `Label("…", systemImage:)`, `navigationTitle("…")` and the like
  take a `LocalizedStringKey`, so a literal is already localized. A custom view that shows a
  title should take `LocalizedStringKey` too, not `String`.
- Anywhere a `String` is needed, write `String(localized: "…")`. Don't build sentences from
  pieces: write the whole sentence with interpolations, so a translation can reorder them.
- A ternary of two literals stays localized. A ternary that mixes a literal with a `String`
  is shown verbatim, so wrap both sides in `String(localized:)`.
- Counts go in the sentence (`"\(count) expenses…"`) and get plural variations in the
  catalog. Polish needs one, few, many and other.
- Format money with `MoneyFormatter`, dates with `FormatStyle` or a template
  (`setLocalizedDateFormatFromTemplate`), and lists with `.formatted(.list(type: .and))`.
- Text the server stores or matches on (backend error reasons, telemetry screen names) stays
  English. `UserFacingError` maps backend reasons to localized sentences.
- Add a `comment:` when a key isn't a sentence (such as `"repeat-unit-day \(count)"`) or
  needs context to translate.

## Polish copy

Polish verbs and possessives change with a person's gender, which Loam doesn't know. Activity
sentences use the present tense ("Julia akceptuje…") and impersonal forms ("wydano"), and
names go after a colon ("przez: Julia") so they never need declining.

## Choosing a language

Loam follows the iPhone's language, and iOS lets people pick a language for Loam alone under
Settings > Apps > Loam > Language. Profile > Settings > Language opens that page.

## Siri and notifications

- Siri doesn't support Polish, so App Shortcut phrases are English only. When Loam adds a
  language Siri supports, add `AppShortcuts.xcstrings` with phrases for it.
- Push notification text is written by `supabase/functions/_shared/push_content.ts` and is
  English for now.

## Adding a language

1. Add the language code to `knownRegions` in `Loam.xcodeproj/project.pbxproj`, or add it in
   Xcode under Project > Info > Localizations. After `xcodegen generate`, check it is still
   there. The check also reads languages from the catalogs, so a dropped region still fails CI.
2. Fill in its column in both catalogs in Xcode's String Catalog editor.
3. If it isn't listed in `PLURAL_FORMS` in `scripts/check-localizations.py`, add its CLDR
   plural categories.
4. Run `python3 scripts/check-localizations.py`. CI runs it on every PR, and again after the
   iOS build to catch strings the code uses that the catalog doesn't have.
