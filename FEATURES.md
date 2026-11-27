# Funzionalità da valutare

Elenco ricavato dal README e dalla struttura del progetto, senza aver letto tutto il codice: alcune voci potrebbero esistere già. Non sono necessariamente tutte da fare. Si spunta `[x]` quando una voce è realizzata.

## PDF

- [ ] OCR per i PDF scansionati (ricerca e selezione del testo)
- [ ] Compilazione dei moduli (AcroForm)
- [ ] Firma
- [ ] Disegno a mano libera
- [ ] Forme, frecce e caselle di testo
- [ ] Redazione
- [ ] Unione e divisione di PDF
- [ ] Estrazione di pagine
- [ ] Esportazione delle pagine come immagini
- [ ] Compressione
- [ ] Ritaglio dei margini (cropping)
- [ ] Confronto tra PDF
- [ ] Riempimento automatico dei moduli
- [ ] Elenco riepilogativo di tutte le annotazioni, con filtro e ricerca
- [ ] Esportazione delle annotazioni in Markdown (oggi solo per EPUB)
- [x] Segnalibri salvati nel file PDF (nell'indice, voce "PageFlow Bookmarks"), non solo sul Mac
- [ ] Modalità lettura notturna con ricolorazione delle pagine
- [ ] Modalità presentazione
- [ ] Supporto agli stylus

## EPUB e libri

- [ ] Altri formati: MOBI, AZW3, FB2, CBZ, CBR (fumetti)
- [ ] Libri con DRM
- [ ] Libreria con copertine, collezioni, tag, stato di lettura e statistiche (tempo, velocità, obiettivi)
- [ ] Dizionario, traduzione e ricerca sul testo selezionato
- [ ] Sincronizzazione di posizione e annotazioni tra dispositivi
- [ ] Lettura ad alta voce per PDF e Markdown (oggi solo per i libri)

## Markdown

- [x] Export in PDF, HTML e DOCX (File > Export As)
- [ ] Pannello dei backlink
- [ ] Vista a grafo
- [ ] Tag
- [ ] Frontmatter YAML
- [ ] Ricerca full-text su tutta la vault
- [ ] Creazione di nuove note da un wiki-link mancante
- [ ] Template
- [ ] Note giornaliere
- [ ] Modalità sorgente pura
- [x] Split view tra sorgente e anteprima (anteprima non modificabile su foglio bianco, doppio clic porta alla riga del sorgente)
- [ ] Editor drag and drop dei titoli nel pannello della struttura
- [ ] Footnote
- [ ] Callout in stile Obsidian
- [ ] Trascrizione e incorporamento di altre note (`![[…]]`)
- [ ] Correttore ortografico dedicato
- [x] Conteggio di parole e caratteri (già presente)
- [ ] Modalità focus / typewriter
- [ ] Cronologia delle versioni

## App in generale

- [ ] Sincronizzazione iCloud
- [ ] Versione iOS / iPadOS
- [ ] Ricerca globale (Spotlight o in-app) su PDF, libri e note
- [ ] Integrazione con Shortcuts, AppleScript o riga di comando
- [ ] Aggiornamento automatico (updater)
- [ ] Cartelle o aree di lavoro, sessioni salvabili con nome
- [ ] Cronologia dei file recenti con anteprima
- [ ] Plugin o sistema di estensioni
- [ ] Localizzazione (oggi probabilmente solo inglese)
- [ ] Verifica di accessibilità (VoiceOver, Dynamic Type)

## Da migliorare

- [ ] Documentazione e suite di test automatici (nel repo ci sono molti file `Debug/…QA.swift`; i test della larghezza delle tab sono in `Tests/TabWidthLayoutTests`)
- [ ] Prestazioni su libri e PDF molto grandi (cache di impaginazione, ricerca full-text)
- [ ] File che cambiano su disco mentre sono aperti, esteso a PDF ed EPUB (oggi solo Markdown)
- [ ] Annotazioni PDF compatibili con Preview, Acrobat e Skim
- [ ] Commenti delle note `.md` in un formato leggibile da altri editor (oggi un blocco nascosto)
