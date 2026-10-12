# Faster Whisper XXL / MOSS / ElevenLabs / VNAI Gemini + AI Translation

PowerShell workflow για:

1. transcription με `faster-whisper-xxl.exe`, MOSS Transcribe-Diarize, ElevenLabs Scribe v2 ή VNAI Pro Gemini
2. μετάφραση του `.srt` με AI provider ή απευθείας μετάφραση του media με ElevenLabs Dubbing

Το MOSS προσθέτει speaker diarization: ξεχωρίζει τους ομιλητές ως `S01`,
`S02` κ.λπ. και κρατά αυτή την πληροφορία κατά τη μετάφραση/QA.

## Προετοιμασία

Μπορείς να βάλεις το OpenAI API key στο τρέχον PowerShell session:

```powershell
$env:OPENAI_API_KEY = "your_api_key_here"
```

Αν δεν το έχεις βάλει, το script θα σου το ζητήσει όταν φτάσει στη μετάφραση.

Αν το `faster-whisper-xxl.exe` δεν είναι στο `PATH` ή μέσα σε αυτόν τον φάκελο, το script θα ανοίξει file picker για να το διαλέξεις. Το path αποθηκεύεται τοπικά στο `.faster-whisper-config.json`, ώστε να μην το ξαναζητάει κάθε φορά.

Από default, τα `.srt` αρχεία γράφονται στον ίδιο φάκελο με το video.

## Επιλογή audio track

Το **Audio track** λειτουργεί με **Faster Whisper XXL, MOSS, ElevenLabs και VNAI Pro Gemini**,
τόσο στο web interface όσο και στο παράθυρο της εφαρμογής.
Επίλεξε `Track 1` για το πρώτο audio track, `Track 2` για το δεύτερο κ.λπ.
Η αρίθμηση μετρά μόνο τα audio tracks, όχι το video ή τους ενσωματωμένους υπότιτλους.
Το `Auto - prefer English` προτιμά το πρώτο track με αγγλική ένδειξη γλώσσας
στα metadata· αν δεν υπάρχει τέτοια ένδειξη, χρησιμοποιεί το πρώτο audio track.
Στο **Windows app**, μόλις επιλέξεις ή επικολλήσεις το path ενός αρχείου,
η λίστα δείχνει μόνο τα πραγματικά audio tracks με γλώσσα και τίτλο όπου υπάρχουν
(π.χ. `Track 1 - Πολωνικά`, `Track 2 - Αγγλικά`). Το Auto δείχνει επίσης ποιο
track θα επιλέξει. Ο πλήρης τίτλος φαίνεται στην ανοιχτή λίστα και στο tooltip.
Για φάκελο ή YouTube, όπου δεν είναι ακόμη γνωστό ένα συγκεκριμένο αρχείο,
εμφανίζονται αριθμημένες επιλογές με σχετική ένδειξη. Στο web interface
οι επιλογές παραμένουν αριθμημένες από 1 έως 32.

Πριν από κάθε μεταγραφή, η εφαρμογή ελέγχει τα tracks με FFprobe και ετοιμάζει
μόνο τον επιλεγμένο ήχο με FFmpeg. Στο log εμφανίζονται ο αριθμός, η γλώσσα
και ο τίτλος, όταν υπάρχουν. Αν το track δεν υπάρχει ή το αρχείο δεν έχει ήχο,
η μεταγραφή σταματά με σφάλμα. Το προσωρινό WAV αφαιρείται μετά τη μεταγραφή,
και το αρχικό αρχείο παραμένει ανέπαφο. Το `Skip transcription` παρακάμπτει
και την προετοιμασία ήχου. Σε φάκελο, ο ίδιος αριθμός track εφαρμόζεται σε κάθε αρχείο.
Για YouTube, η επιλογή αφορά τα tracks που περιέχει το αρχείο μετά τη λήψη.
Η ανεξάρτητη υπηρεσία **ElevenLabs Dubbing** παραμένει μετάφραση του αρχικού media.

Από γραμμή εντολών: `-AudioTrack 2` (ή `-AudioTrack 0` για Auto).
Για μη αγγλικό ήχο στο Faster Whisper επίλεξε πολυγλωσσικό model, π.χ. `medium`
ή `large-v3`, αντί για `medium.en`.

Δοκιμές επιλογής/απομόνωσης ήχου: `python tools/test_audio_tracks.py -v`.

## Transcription με VNAI Pro Gemini

Στο desktop ή web επίλεξε **Transcription engine → VNAI Pro Gemini (cloud)**.
Διαθέσιμα μοντέλα: `gemini-3.8-flash` (προεπιλογή), `gemini-3.7-flash`, `gemini-3.6-flash`.
Χρησιμοποιείται το ίδιο αποθηκευμένο κλειδί με τον translation provider **VNAI Pro Gemini**,
ή η μεταβλητή `VNAIPRO_GEMINI_API_KEY`. Στο desktop το κουμπί **VNAI Gemini API key**
αλλάζει αυτό το κοινό κλειδί ακόμη και με Skip translation. Στο web το προαιρετικό
πεδίο κλειδιού ισχύει μόνο για το transcription του συγκεκριμένου job και δεν αποθηκεύεται.

Απαιτούνται Python και FFmpeg, χωρίς επιπλέον Python packages. Το επιλεγμένο audio track
αποστέλλεται στο VNAI Pro σε τμήματα 60 δευτερολέπτων και παράγεται `.srt` στην αρχική
γλώσσα. Η μετάφραση συνεχίζει με τον ανεξάρτητα επιλεγμένο translation provider.
Πριν ξεκινήσει το transcription ελέγχεται η πρόσβαση του κλειδιού στο συγκεκριμένο μοντέλο·
δεν αλλάζει αυτόματα μοντέλο. Οι κλήσεις χρησιμοποιούν το υπόλοιπο του VNAI Pro.

Οι χρονισμοί παράγονται από το μοντέλο και χρειάζονται έλεγχο, ιδιαίτερα κοντά στα όρια
των τμημάτων όπου μπορεί να κοπεί μια λέξη. Δεν υποστηρίζονται speaker labels σε αυτή τη
μηχανή. Αν αποτύχει ένα τμήμα ή επιστραφούν μη έγκυροι χρονισμοί, το job αποτυγχάνει
χωρίς να αντικαταστήσει υπάρχον SRT με ελλιπές αποτέλεσμα.

```powershell
.\Transcribe-And-Translate.ps1 -InputPath "C:\Videos\episode.mp4" -TranscriptionEngine VNAIGemini -VnaiGeminiModel gemini-3.8-flash -SkipTranslation
```

Η σύνδεση χρησιμοποιεί το Gemini `generateContent` audio API μέσω VNAI Pro
([μορφή αιτήματος ήχου](https://ai.google.dev/gemini-api/docs/generate-content/audio)).
Έλεγχοι χωρίς API χρεώσεις: `python -m unittest tools.test_vnai_gemini_transcribe -v`.

## Προεπιλογές εφαρμογής

Στο Desktop UI, επίλεξε **Translation → Provider → Change translation API key**
για να αλλάξεις το κλειδί του συγκεκριμένου παρόχου (OpenAI, VNAI Pro,
VNAI Pro Claude, VNAI Pro Gemini, Gemini, AI Prime Tech
ή ElevenLabs Dubbing). Το πεδίο εισαγωγής είναι κρυφό και το **Cancel** κρατά το
υπάρχον κλειδί. Η αλλαγή αποθηκεύεται τοπικά στο `.faster-whisper-config.json`
και χρησιμοποιείται και μετά το επόμενο άνοιγμα, με προτεραιότητα έναντι παλιών
environment keys. Κάθε πάροχος έχει ξεχωριστό κλειδί· το ElevenLabs Dubbing
μοιράζεται το κλειδί του ElevenLabs transcription. Στο **Local NLLB** ή με
**Skip translation**, το κουμπί είναι απενεργοποιημένο.

Για GPT key από το `apikey.vnaipro.app`, επίλεξε **VNAI Pro** — όχι OpenAI.
Για το ξεχωριστό Claude key του ίδιου dashboard, επίλεξε **VNAI Pro Claude**.
Για το ξεχωριστό Gemini key/group, επίλεξε **VNAI Pro Gemini** και όχι τον
επίσημο provider **Gemini**. Τα τρία VNAI κλειδιά αποθηκεύονται ανεξάρτητα και
δεν αντικαθιστούν το ένα το άλλο. Και οι τρεις επιλογές χρησιμοποιούν το
OpenAI-compatible endpoint
`https://apikey.vnaipro.app/v1/chat/completions`. Το VNAI Pro περιλαμβάνει τα
GPT models `gpt-5.6-sol` (προεπιλογή) και `gpt-5.6-terra`. Το VNAI Pro Claude
περιλαμβάνει τα aliases `claude-sonnet-4-6` (προεπιλογή), `claude-sonnet-5`,
`claude-fable-5`, `claude-fable-5-1`, `claude-opus-4-6`, `claude-opus-4-7`,
`claude-opus-4-8`, `claude-opus-5` και `claude-opus-5-5`. Δεν χρειάζεται
Anthropic key. Η πραγματική πρόσβαση εξαρτάται από το αντίστοιχο VNAI key,
το επιλεγμένο group, το ενεργό model channel και το διαθέσιμο quota.
Για το VNAI Pro Gemini υπάρχουν αρχικές επιλογές `gemini-3.8-flash`,
`gemini-3.7-flash` και `gemini-3.6-flash`. Μόλις
αποθηκευτεί το VNAI Gemini key από το Desktop UI, η εφαρμογή διαβάζει το
`/v1/models` και αντικαθιστά τη λίστα με τα ακριβή models του συγκεκριμένου key.
Αν ένα παλιό model δεν ανήκει πλέον στο key, επιλέγει αυτόματα το πρώτο
διαθέσιμο Gemini model πριν ξεκινήσει η μετάφραση.
Πριν ξεκινήσει η μετάφραση, η εφαρμογή ελέγχει το `/v1/models`. Αν το key είναι
έγκυρο αλλά δεν έχει πρόσβαση στο επιλεγμένο μοντέλο, σταματά πριν στείλει τα
chunks και ζητά ενεργοποίηση model access από τον provider. Για Claude model,
το VNAI group πρέπει να περιλαμβάνει ενεργό Claude channel.

Οι προεπιλογές του Desktop UI είναι: `ElevenLabs Scribe v2 (cloud)`, model
`scribe_v2`, μετάφραση με `OpenAI` / `gpt-5.4-mini`, γλώσσα `Greek` και
`SRT cleanup: None`. Τα `Skip transcription`, `Show S01 in final`, `Skip
translation`, `Translation QA pass`, `Auto gender` και `Voice gender detection`
ξεκινούν απενεργοποιημένα.

Σε προσωρινό OpenAI `429` η εφαρμογή κάνει καθυστερημένες επαναλήψεις. Αν το
API επιστρέψει `insufficient_quota`, `credit_balance` ή άλλο πρόβλημα billing,
εμφανίζεται οδηγία για προσθήκη OpenAI API balance χωρίς άσκοπες επαναλήψεις.
Αν αποτύχει η μετάφραση, το source
SRT διατηρείται· μπορείς να το επιλέξεις με `Skip transcription` για νέα
προσπάθεια χωρίς δεύτερη χρέωση ElevenLabs. Η αφαίρεση των `S01/S02` κάνει
επαναλήψεις σε προσωρινό file lock και δεν καλύπτει πλέον το αρχικό API error.

## Web UI για τάμπλετ

Τρέξε το `Run-Web-App.bat` και άνοιξε στο τάμπλετ τη διεύθυνση `Tablet` που
εμφανίζεται στο παράθυρο. Κατά το ανέβασμα αρχείου εμφανίζεται επιλογή
`Ακύρωση αποστολής`. Κάθε ενεργό job στη λίστα `Jobs` έχει επίσης κουμπί
`Ακύρωση`, το οποίο σταματά το PowerShell job και τις θυγατρικές διεργασίες
transcription/translation. Μια χρεώσιμη cloud API κλήση που έχει ήδη σταλεί
ενδέχεται να έχει ήδη καταγραφεί από τον πάροχο.

## Εγκατάσταση MOSS

Το Faster Whisper συνεχίζει να λειτουργεί χωρίς καμία αλλαγή. Για να
ενεργοποιήσεις επιπλέον το MOSS, τρέξε μία φορά:

```text
Setup-MOSS.bat
```

Το setup δημιουργεί απομονωμένο `.venv-moss`, εγκαθιστά το CPU PyTorch runtime
και κατεβάζει το model `OpenMOSS-Team/MOSS-Transcribe-Diarize`. Η πρώτη
εγκατάσταση/λήψη είναι μεγάλη και μπορεί να διαρκέσει.

Στο Web UI ή στο desktop παράθυρο επίλεξε:

```text
Transcription engine: MOSS + speaker diarization
```

Το MOSS γράφει:

- `episode.srt`: source SRT με `S01/S02`
- `episode.moss.json`: δομημένα speaker segments
- `episode.moss.meta.json`: model/runtime metadata

Τα speaker labels χρησιμοποιούνται εσωτερικά για καλύτερη συνέπεια στη
μετάφραση. Η επιλογή `Show S01/S02 in final SRT` ορίζει αν θα εμφανίζονται και
στο τελικό μεταφρασμένο αρχείο. Από default κρύβονται μόνο από το τελικό SRT.

Στο συγκεκριμένο Windows/AMD σύστημα το επίσημο MOSS runtime λειτουργεί σε CPU.
Για να προστατεύεται η RAM, τα τοπικά MOSS transcriptions εκτελούνται ένα-ένα.

## ElevenLabs Scribe v2

Η επιλογή `ElevenLabs Scribe v2 (cloud)` κάνει transcription και speaker
diarization στο cloud. Η εφαρμογή:

1. δημιουργεί προσωρινό mono MP3 με FFmpeg,
2. το ανεβάζει στο ElevenLabs με το model `scribe_v2`,
3. γράφει μόνο το source `episode.srt`,
4. συνεχίζει προαιρετικά με την υπάρχουσα μετάφραση και το QA pass.

Στο Desktop UI το API key ζητείται κρυφά την πρώτη φορά. Στο Web UI μπορείς
να το βάλεις στο πεδίο `ElevenLabs API key` ή στο αρχείο `.env`:

```text
ELEVENLABS_API_KEY=your_api_key_here
```

Το `Expected speakers` μένει `0` για αυτόματη ανίχνευση ή δέχεται αριθμό
από 1 έως 32. Το checkbox `Show S01/S02 in final SRT` ελέγχει αν τα speaker
labels θα εμφανίζονται στο παραγόμενο transcription SRT και στο τελικό
μεταφρασμένο SRT. Όταν είναι κλειστό, τα labels διατηρούνται μόνο εσωτερικά
κατά τη μετάφραση για καλύτερο context και αφαιρούνται από τα αρχεία εξόδου.

Στο Desktop UI, όταν επιλεγεί Scribe v2 ή ElevenLabs Dubbing, το κουμπί
`Refresh credits` εμφανίζει το ενεργό πλάνο και τα credits που
απομένουν. Διαβάζει το πραγματικό υπόλοιπο από το ElevenLabs API και δεν
αλλάζει χρεώσεις, όρια ή στοιχεία του λογαριασμού.
Το endpoint του υπολοίπου χρειάζεται την εσωτερική άδεια `user_read`, η οποία
δεν εμφανίζεται ως ξεχωριστή επιλογή στον τρέχοντα ElevenLabs API-key editor.
Για να λειτουργήσει το `Refresh credits`, απενεργοποίησε το `Restrict Key` και
πάτησε `Save Changes`. Ένα restricted key με `Speech to Text: Access` συνεχίζει
να λειτουργεί για μεταγραφή, αλλά δεν μπορεί να εμφανίσει το συνολικό υπόλοιπο.
Το ElevenLabs API key είναι το πλήρες secret που αρχίζει από `sk_`. Το μεγάλο
hexadecimal **Key ID** που φαίνεται στη λίστα των keys δεν είναι API key και
απορρίπτεται πριν γίνει request. Αν το key έχει λήξει ή απενεργοποιηθεί, το `Change API key` αποθηκεύει νέο key
για το Desktop UI, ακόμη κι αν υπάρχει παλιότερο key στο `.env`.

Με την επιλογή ενός μεμονωμένου αρχείου media, το Desktop UI δείχνει και
εκτίμηση χρέωσης από τη διάρκειά του: Scribe v2 περίπου 2.200 credits/ώρα και
automatic Dubbing with watermark περίπου 3.300 credits/λεπτό. Η ένδειξη είναι
εκτίμηση και οι τιμές του ElevenLabs μπορεί να αλλάξουν. Για YouTube η διάρκεια
γίνεται διαθέσιμη μετά το download, ενώ για φάκελο η εκτίμηση ισχύει ανά αρχείο.

## ElevenLabs Dubbing

Η επιλογή `Provider: ElevenLabs Dubbing` χρησιμοποιεί την υπηρεσία Dubbing
του ElevenLabs για τη μετάφραση. Η εφαρμογή:

1. εκτελεί κανονικά το επιλεγμένο transcription engine (π.χ. Scribe v2),
2. ανεβάζει το αρχικό audio/video στο ElevenLabs Dubbing,
3. περιμένει να ολοκληρωθεί το automatic dubbing job,
4. κατεβάζει το transcript της γλώσσας-στόχου ως word-timed JSON,
5. ταξινομεί τις μεταφρασμένες λέξεις χρονικά και αντιστοιχίζει κάθε λέξη
   στο κατάλληλο αρχικό cue του Scribe με βάση τον χρόνο της,
6. εφαρμόζει το επιλεγμένο τοπικό SRT cleanup.

Για ελληνικά άφησε `Target language: Greek`. Χρησιμοποιείται το ίδιο
`ELEVENLABS_API_KEY` με το Scribe. Το Dubbing είναι ξεχωριστή χρεώσιμη υπηρεσία
και δημιουργεί dubbing project στον λογαριασμό ElevenLabs. Το `dubbing_id`
εμφανίζεται στο log της εκτέλεσης. Η κανονική έξοδος του
Dubbing provider είναι το μεταφρασμένο `.srt`, χωρίς βοηθητικό JSON.

Όταν το source SRT φαίνεται να έχει έναν ομιλητή και οι υπόλοιπες φωνές του
Dubbing transcript έχουν μόνο ελάχιστες λέξεις, κρατείται ο κυρίαρχος ομιλητής
ώστε σύντομα background ad-libs να μη χαλούν τη σειρά των υποτίτλων. Σε κανονικό
διάλογο κρατούνται όλοι οι ομιλητές. Το αρχικό ευθυγραμμισμένο SRT έχει το ίδιο
πλήθος cues και το ίδιο χρονικό τέλος με το source Scribe SRT· το τελικό cleanup
μπορεί να ενώσει ή να χωρίσει cues μόνο όταν χρειάζεται για αναγνωσιμότητα.

Στις άδειες του API key όρισε το **Dubbing** σε **Write**· αυτή είναι η επιλογή
**Read + Write**. Η εφαρμογή κάνει read-only preflight έλεγχο πριν αρχίσει τη
μεταγραφή, ώστε να μη δημιουργεί μόνο αγγλικό source SRT όταν λείπει η άδεια.

Το Dubbing request ενεργοποιεί watermark για συμβατότητα με το δωρεάν πλάνο.
Αυτό αφορά το παραγόμενο dubbed audio/video και δεν αλλάζει το κείμενο του SRT.

Το `Translation QA pass`, το `Auto gender` και το `Voice gender detection` δεν
στέλνονται στο Dubbing API. Το `Context / gender hints` εξακολουθεί να μπορεί να
χρησιμοποιηθεί από το τελικό τοπικό subtitle quality pass.

## Χρήση με File Explorer

Κάνε διπλό κλικ στο:

```text
Run-Transcribe-And-Translate.bat
```

Θα ανοίξει παράθυρο επιλογής αρχείου. Διάλεξε το video/audio αρχείο και το τελικό `.Greek.srt` θα γραφτεί στον ίδιο φάκελο.

Μετά θα ανοίξει παράθυρο επιλογής transcription model, π.χ. `small`, `medium`, `large-v3`, `large-v3-turbo`. Μπορείς και να πληκτρολογήσεις custom model name.

Αν είναι η πρώτη φορά και δεν βρεθεί αυτόματα το `faster-whisper-xxl.exe`, θα ανοίξει και δεύτερο παράθυρο για να διαλέξεις το executable.

Το ίδιο γίνεται και αν τρέξεις απλώς:

```powershell
.\Transcribe-And-Translate.ps1
```

## Παράδειγμα για ένα αρχείο

```powershell
.\Transcribe-And-Translate.ps1 `
  -InputPath "D:\video\episode.mp4" `
  -FasterWhisperPath "D:\tools\Faster-Whisper-XXL\faster-whisper-xxl.exe" `
  -SourceLanguage "English" `
  -TargetLanguage "Greek"
```

## Παράδειγμα για ολόκληρο φάκελο

```powershell
.\Transcribe-And-Translate.ps1 `
  -InputPath "D:\video" `
  -FasterWhisperPath "D:\tools\Faster-Whisper-XXL\faster-whisper-xxl.exe" `
  -WhisperModel "large-v3" `
  -Device "cpu" `
  -ComputeType "int8" `
  -TargetLanguage "Greek"
```

## Χρήσιμες επιλογές

- `-SourceLanguage auto`: αφήνει το Whisper να ανιχνεύσει τη γλώσσα.
- `-OutputDir "D:\subtitles"`: προαιρετικό override αν δεν θέλεις export δίπλα στο video.
- `-OutputFormat srt`: παράγει SubRip subtitles.
- `-WhisperModel large-v3`: παρακάμπτει το model picker και χρησιμοποιεί απευθείας αυτό το transcription model.
- `-TranscriptionEngine MOSS`: χρησιμοποιεί MOSS αντί για Faster Whisper.
- `-TranscriptionEngine ElevenLabs`: χρησιμοποιεί το cloud Scribe v2 API.
- `-TranslationProvider "ElevenLabs Dubbing"`: μεταφράζει το αρχικό media μέσω ElevenLabs και κατεβάζει το target-language SRT.
- `-ElevenLabsModel scribe_v2`: επιλέγει το ElevenLabs transcription model.
- `-ElevenLabsNumSpeakers 0`: αυτόματη ανίχνευση ομιλητών (`1`–`32` για συγκεκριμένο μέγιστο).
- `-MossModel OpenMOSS-Team/MOSS-Transcribe-Diarize`: επιλέγει MOSS model.
- `-MossDevice auto`: χρησιμοποιεί το διαθέσιμο MOSS device (`cpu` σε αυτό το Windows/AMD PC).
- `-MossMaxNewTokens 0`: υπολογίζει αυτόματα output budget από τη διάρκεια του media.
- `-ShowSpeakerLabels $true`: κρατά τα `S01/S02` και στο τελικό μεταφρασμένο SRT.
- `-OpenAIModel gpt-5.5`: το OpenAI model για τη μετάφραση.
- `-MaxParallelTranslations 3`: μεταφράζει έως τρία ανεξάρτητα OpenAI chunks ταυτόχρονα, διατηρώντας την αρχική σειρά στο τελικό SRT. Η τιμή `1` επαναφέρει τη σειριακή λειτουργία.
- `-EnableTranslationQaPass $true`: κάνει δεύτερο QA pass συγκρίνοντας το English source `.srt` με το Greek draft `.srt` για να διορθώσει χαμένο νόημα, ονόματα και περίεργες αποδόσεις.
- `-SrtPostProcessingMode SentenceFlow`: διορθώνει πιο φυσικά τη ροή προτάσεων, ειδικά όταν η τελευταία λέξη μιας πρότασης κολλάει στον επόμενο υπότιτλο.
- `-MaxReadingCharsPerSecond 20`: θέτει τον στόχο αναγνωσιμότητας του τελικού SRT. Το τελικό quality pass συγχωνεύει πολύ μικρά cues, ανακατανέμει sentence-level timings, αφαιρεί overlaps και κρατά έως δύο γραμμές των 58 χαρακτήρων.
- `-MinCueDurationSeconds 0.8`: ορίζει την ελάχιστη επιθυμητή διάρκεια κάθε cue μετά τη χρονική εξομάλυνση.
- `-SkipTranscription`: χρησιμοποιεί ήδη υπάρχον `.srt` στον φάκελο του video ή στο `-OutputDir`.
- `-SkipTranslation`: τρέχει μόνο transcription.

Τα τελικά αρχεία γράφονται δίπλα στο video, π.χ.:

- `episode.srt`
- `episode.Greek.srt`


## Τοπική μετάφραση NLLB 600M σε CPU

Στο Provider επιλέξτε **Local — NLLB 600M** (στο Windows παράθυρο: **Local NLLB**).
Το μοντέλο Meta `facebook/nllb-200-distilled-600M` εκτελείται με CTranslate2 INT8,
4 CPU threads και beam size 4. Το OpenAI / GPT-5.4-mini παραμένει διαθέσιμο.

- Αρχική εγκατάσταση: `Setup-NLLB.bat`. Δημιουργεί ξεχωριστό `.venv-nllb`, κατεβάζει
  το μοντέλο και αποθηκεύει την έκδοση INT8 στο `tools/models/nllb-600m-int8`.
  Το κατέβασμα και η μετατροπή χρειάζονται internet και αρκετά GB ελεύθερου δίσκου.
- Μετά την εγκατάσταση, η μετάφραση λειτουργεί offline χωρίς API key.
- Για υπάρχον SRT: επιλέξτε το αρχείο, **Skip transcription**, Provider **Local — NLLB 600M**,
  Source language **English**, Target language **Greek** και **Start job**.
- Απαιτείται συγκεκριμένη γλώσσα πηγής· το `auto` δεν υποστηρίζεται. Γίνονται δεκτά
  English/Greek και κωδικοί NLLB όπως `eng_Latn` / `ell_Grek`.
- Μεταφράζει SRT ή το SRT που παράγει η μεταγραφή ενός βίντεο. Η απευθείας μετάφραση TXT
  δεν υποστηρίζεται. Διατηρεί αριθμούς cues, χρονισμούς, αλλαγές γραμμής και tags.
- QA pass, auto gender, voice gender, context hints και επεξεργασία χρονισμών δεν
  εφαρμόζονται στην τοπική επιλογή. Η μετάφραση δεν συνεπάγεται τοπική μεταγραφή:
  το ElevenLabs εξακολουθεί να χρησιμοποιεί cloud αν επιλεγεί ως transcription engine.
- Δεν έχει τεκμηριωθεί ισοδύναμη ποιότητα με GPT-5.4-mini. Ελέγχετε το αποτέλεσμα,
  ιδιαίτερα σε σύντομες ατάκες, ιδιωματισμούς, ονόματα και φύλο ομιλητών.

Το NLLB διατίθεται με άδεια CC-BY-NC-4.0· δείτε την επίσημη model card:
https://huggingface.co/facebook/nllb-200-distilled-600M

Έλεγχος τοπικής μετάφρασης και ακεραιότητας SRT:
`.venv-nllb\Scripts\python.exe -m unittest discover -s tools -p test_nllb.py`


### NLLB: ομαδοποίηση προτάσεων, αριθμοί και γλωσσάρι (sentence_v2)

Η τοπική μετάφραση ενώνει τις απλές αλλαγές γραμμής και τις προτάσεις που
συνεχίζονται σε επόμενο cue (έως 4 cues, κενό έως 1,5 s, έως 600 χαρακτήρες).
Δεν ενώνει διαφορετικούς ρητά σημειωμένους ομιλητές ή διαφορετική μορφοποίηση.
Κάθε ολοκληρωμένη πρόταση μεταφράζεται χωριστά, για να περιοριστούν οι παραλείψεις.
Το ενιαίο ελληνικό κείμενο μοιράζεται αναλογικά σε ολόκληρες λέξεις στα αρχικά cues:
οι χρονισμοί παραμένουν ίδιοι, αλλά η αντιστοίχιση λέξεων στον ήχο είναι προσεγγιστική.

Οι αριθμοί προστατεύονται. Για ονόματα και ειδικούς όρους, τοποθετήστε δίπλα
στο αρχικό SRT/βίντεο ένα UTF-8 JSON με το ίδιο βασικό όνομα και κατάληξη
`.nllb-glossary.json`, π.χ. `episode.nllb-glossary.json` για `episode.srt`:

```json
{
  "source_language": "eng_Latn",
  "target_language": "ell_Grek",
  "terms": {"Summer": "Σάμερ", "Hobie": "Χόμπι"}
}
```

Το γλωσσάρι ισχύει μόνο για αυτό το αρχείο. Οι μεγαλύτερες φράσεις έχουν
προτεραιότητα. Οι αποδόσεις εισάγονται ακριβώς όπως γράφονται, επομένως για
όρους με άρθρα/πτώσεις προτιμήστε ολόκληρη τη φράση. Η αυτόματη χρήση λειτουργεί
και όταν το πρόγραμμα αντιγράφει το SRT σε διαφορετικό φάκελο εξόδου.
Το Python εργαλείο δέχεται επίσης `--glossary PATH`.

Αν το μοντέλο αλλοιώσει ή παραλείψει προστατευμένο όρο, εφαρμόζεται εναλλακτική
μετάφραση των γύρω τμημάτων και καταγράφεται προειδοποίηση για έλεγχο φυσικότητας.
Προστίθεται `.qa.json` με προειδοποιήσεις, αριθμούς cues και χρόνο εκτέλεσης.
Οι προειδοποιήσεις είναι ευρετικοί έλεγχοι και δεν πιστοποιούν την ποιότητα.
Τα νέα αρχεία από το πρόγραμμα έχουν επίθημα `_sentence_v2.srt`, ώστε να
ξεχωρίζουν από την προηγούμενη τοπική μετάφραση.
