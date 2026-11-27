# Glossa: separazione dall'identità di PageFlow

Documento tecnico di migrazione. **Descrive un lavoro futuro**: nulla di quanto sotto è implementato, salvo la parte «Cosa è già stato fatto». L'identificatore resta `com.raccoontechnologies.PageFlow`; non si cambiano firma, entitlements, percorsi di Application Support né dati esistenti.

Principi, in ordine di importanza:

1. **Non si muove e non si cancella nulla di PageFlow.** Si legge, si copia, si lascia dov'è.
2. **Opt-in o comunicato chiaramente.** Nessuna copia di dati parte senza che l'utente l'abbia visto e accettato.
3. **Idempotente e reversibile.** Rieseguire non duplica; si può tornare indietro senza perdere nulla.
4. **Il nuovo codice non aggiunge dipendenze da chiavi o percorsi di PageFlow.** I dati nuovi vivono sotto `glossa.*`.

---

## 0. Stato attuale

### Cosa è già stato fatto

- Le preferenze nuove usano `glossa.*`:

| Chiave | Contenuto |
|---|---|
| `glossa.markup.layer.highlight.v1`, `glossa.markup.layer.underline.v1` | livello delle personalizzazioni dei colori (versionato) |
| `glossa.markup.layer.highlight.backup`, `glossa.markup.layer.underline.backup` | copia di riserva del livello, scritta dal reset |
| `glossa.markup.comment.backup` | copia di riserva dei colori dei commenti, scritta dal reset |
| `glossa.tabs.scale` | dimensione delle tab |
| `glossa.markdown.pageMeasure` | larghezza della pagina Markdown |

- `settings.tabScale` e `settings.markdownPageMeasure` (scritte dalle build precedenti di Glossa) si **leggono ancora come ripiego** se la chiave `glossa.*` non esiste, e non si scrivono più.
- Le liste dei colori vecchie (`settings.highlightPresets`, `settings.underlinePresets`) e `settings.markupPaletteVersion` sono **lasciate intatte** e lette una sola volta dalla migrazione dei colori (`PaletteStore.migrateIfNeeded`). Glossa non scrive mai in quelle chiavi.
- I segnalibri dei PDF sono scritti nel file (voce dell'indice «Glossa Bookmarks»), non in chiavi dell'app. La voce «PageFlow Bookmarks» si legge ancora.

### Inventario di ciò che l'app salva

Dominio preferenze: `~/Library/Preferences/com.raccoontechnologies.PageFlow.plist` (build senza sandbox; la build firmata col sandbox userebbe invece il container `~/Library/Containers/com.raccoontechnologies.PageFlow/`).

| Dato | Dove | Contiene permessi? | Politica di importazione proposta |
|---|---|---|---|
| Impostazioni dell'interfaccia (`settings.*`: tab, barra, scorciatoie, margini, tema, caratteri…) | preferenze | no | **Importare** (elenco consentito) |
| Colori dei commenti (`settings.commentPresets`) | preferenze | no | Importare |
| Colori evidenziatori e sottolineature | preferenze (`settings.highlightPresets`, `…underlinePresets`) | no | Importare **le chiavi vecchie come origine** e far girare la migrazione dei colori, che le classifica |
| Posizioni di lettura (`documentViewStates.v2`) | preferenze | no (percorsi) | Importare |
| File recenti (`recentFiles`) | preferenze | **sì** (segnalibro con scope di sicurezza) | Vedi §4 |
| Ripristino sessione (`sessionRestore.v1`) | preferenze | **sì** | Vedi §4, **non** importare per impostazione predefinita |
| Permessi sulle cartelle (`folderAccessBookmarks.v1`) | preferenze | **sì** | Vedi §5 |
| Immagini trascinate (`droppedImageBookmarks.v1`) | preferenze | **sì** | Vedi §5 |
| Segnalibri locali (`bookmarks:<percorso>`) | preferenze | no | Importare (già nel file per i PDF modificati) |
| Avviso «lettore PDF predefinito» (`hasShownDefaultPDFPrompt`) | preferenze | no | **Non** importare: la nuova identità deve poterlo chiedere |
| Posizione e dimensione delle finestre (`NSWindow Frame …`), chiavi `NS*` del sistema | preferenze | no | Non importare |
| Recupero delle note (`Application Support/PageFlow/Recovery`) | file | no | Vedi §3 |
| Allegati incollati (`Application Support/PageFlow/Attachments`) | file | no | Copiare, vedi §3 |
| Annotazioni EPUB (`Application Support/PageFlow/EPUB Annotations`) | file | no | Copiare, vedi §3 |
| Immagini trascinate temporanee («PageFlow Drops»), file audio temporanei | cartella temporanea | no | Non serve |
| Cache (`~/Library/Caches/com.raccoontechnologies.PageFlow`) | cache | no | Non importare |

---

## 1. Nuovo identificatore

**Scelta.** Un identificatore DNS inverso su un dominio che controlli (`<dominio>.Glossa`), deciso una volta sola: dopo la pubblicazione non si cambia senza ripetere questa migrazione. Per ora il placeholder è `<NUOVO-ID>`.

**Cosa cambia con esso**
- `PRODUCT_BUNDLE_IDENTIFIER` nelle tre configurazioni del target (`project.pbxproj`). `Info.plist` lo legge da lì.
- Squadra di firma: oggi `DEVELOPMENT_TEAM` è quella del progetto di origine. Una nuova identità richiede la tua squadra, un nuovo profilo e, per la distribuzione sul Mac App Store, un nuovo record dell'app.
- Gli identificatori dei test in `Debug/*QA.swift` (`<id>.RecoveryQA.`, `<id>.RestoreQA.`) vanno derivati dal nuovo.
- Il sottosistema dei log (`com.pageflow`) è indipendente e si può lasciare.
- Il sandbox crea un container nuovo e vuoto: tutto ciò che sta nelle preferenze e in Application Support riparte da zero (da qui il resto del documento).

**Non cambiare insieme** le entitlements, il nome del prodotto o la struttura delle cartelle: un passo alla volta, per poter attribuire i problemi.

## 2. Importazione una tantum delle preferenze

**Quando.** Al primo avvio con la nuova identità, se esiste un dominio di PageFlow e il marcatore `glossa.migration.fromPageFlow.v1` non esiste. Mai silenziosa (vedi «Comunicazione»).

**Lettura della sorgente (sempre in sola lettura)**
- Build senza sandbox: `CFPreferencesCopyAppValue(chiave, "com.raccoontechnologies.PageFlow")` o `UserDefaults(suiteName:)`. Non si scrive mai in quel dominio.
- Build con sandbox: l'app non può leggere il dominio di un'altra app. Due strade: (a) l'utente indica il file `…/com.raccoontechnologies.PageFlow.plist` con un pannello di apertura e l'app lo legge come dizionario (file chiesto, nessuna eccezione al sandbox); (b) una eccezione temporanea di sola lettura (`com.apple.security.temporary-exception.shared-preference.read-only`), che il Mac App Store di norma non accetta. Si consiglia la strada (a).

**Cosa si importa: un elenco consentito, non tutto**
- Si importano le chiavi `settings.*` (tranne le sostituite da `glossa.*`), `documentViewStates.v2` e `bookmarks:*`.
- Le liste dei colori vecchie si importano **così come sono** nelle chiavi vecchie del nuovo dominio, e poi la migrazione dei colori esistente (`PaletteStore`) le classifica: se coincidono con quelle di fabbrica o con `pastel-1` danno un livello vuoto, altrimenti diventano preset dell'utente accanto ai predefiniti Glossa.
- Non si importano: `hasShownDefaultPDFPrompt`, le chiavi `NS*` e le posizioni delle finestre, `sessionRestore.v1` (vedi §4).

**Regole**
- **La destinazione vince:** una chiave già presente nel nuovo dominio non si sovrascrive.
- **Marcatore:** `glossa.migration.fromPageFlow.v1` = `{data, versione dell'app, identificatore sorgente, chiavi importate}`. Scritto per ultimo; la sua presenza rende l'operazione idempotente.
- **Anteprima a secco:** una modalità che produce l'elenco delle chiavi che verrebbero importate senza scrivere nulla.
- **Dati non riconosciuti** (tipo o schema inattesi) si saltano e si registrano, mai si scartano nella sorgente.

**Comunicazione.** Un foglio al primo avvio: cosa verrà copiato (impostazioni, posizioni di lettura, colori, file recenti), «copia, non sposta», e tre scelte: «Importa», «Non ora» (si richiede dal menu e al prossimo avvio) e «Non importare mai» (scrive il marcatore con `skipped`). Un comando permanente nel menu: «Importa da PageFlow…».

## 3. Copia di Application Support, senza cancellare l'originale

**Sorgente:** `~/Library/Application Support/PageFlow/{Recovery, Attachments, "EPUB Annotations"}` (o nel container se la build è con sandbox). **Destinazione:** `~/Library/Application Support/Glossa/…` (la cartella nuova va decisa insieme al nuovo identificatore).

**Metodo**
- Copia, mai spostamento: `FileManager.copyItem`, che su APFS clona senza duplicare lo spazio fino alla modifica.
- Si copia in una cartella di appoggio (`Glossa/.import-staging`) e si rinomina in modo atomico a copia finita. Se qualcosa fallisce, si elimina **solo** la cartella di appoggio.
- Se la destinazione esiste già, non si tocca (la destinazione vince). Un file per volta con confronto di dimensione e data per riprendere dopo un'interruzione.
- Controllo dello spazio libero prima di iniziare; avanzamento visibile solo se dura più di un paio di secondi.
- La sorgente non si apre in scrittura, non si cambiano permessi, data o attributi.

**Per cartella**
- **`EPUB Annotations`**: da copiare, perché le evidenziazioni e le note sono indicizzate per identità del libro: senza di essa sparirebbero dall'interfaccia.
- **`Attachments`**: da copiare. Una nota potrebbe puntare a questi file con un percorso assoluto. **Non si riscrivono mai i documenti** dell'utente: i percorsi vecchi restano validi perché l'originale non viene toccato.
- **`Recovery`**: dati volatili di note non salvate. Importarli farebbe riapparire recuperi vecchi di un'altra app: **non copiare per impostazione predefinita**; offrire solo «Includi i recuperi non salvati».

## 4. File recenti e ripristino della sessione

Entrambi salvano, per ogni documento, un **segnalibro con scope di sicurezza** più il percorso. Il segnalibro è legato all'app che l'ha creato.

- **Build senza sandbox in entrambe le identità:** i segnalibri si risolvono; si può importare `recentFiles` com'è, ricostruendo i segnalibri con il nuovo scope alla prima apertura.
- **Build con sandbox:** i segnalibri dell'app vecchia **non** si risolvono nella nuova. Si importa solo l'elenco di percorsi e nomi con un'etichetta «da riautorizzare»: al primo clic l'app chiede il permesso con un pannello già puntato sul file (il flusso di `FolderAccessStore` esiste già) e crea il segnalibro nuovo.
- **`recentFiles`:** importare, con duplicati uniti per percorso canonico (la logica c'è: `pageFlowCanonicalDocumentURL`), massimo 10 voci, i file che non esistono più scartati.
- **`sessionRestore.v1`:** **non** importare di default. Riaprire all'improvviso le finestre che stavano aperte in un'altra app è una sorpresa. Si può offrire «Riapri le ultime finestre di PageFlow» come azione esplicita, con gli stessi limiti di permessi.
- **`documentViewStates.v2`** (posizione di lettura per documento) è indicizzato per percorso canonico e non contiene permessi: importare.

## 5. Segnalibri con scope di sicurezza e permessi sulle cartelle

Riguarda `folderAccessBookmarks.v1`, `droppedImageBookmarks.v1` e i segnalibri dentro `recentFiles` e `sessionRestore.v1`.

- Sono creati con l'opzione `.withSecurityScope` e l'entitlement `com.apple.security.files.bookmarks.app-scope`: **valgono solo per l'app che li ha creati**. Non si possono copiare come dati e aspettarsi che funzionino sotto un'altra identità sandboxed.
- **Regola:** non copiare mai i blocchi di segnalibro tra identità sandboxed. Importare solo i **percorsi** delle cartelle autorizzate e mostrare un elenco «Cartelle da riautorizzare»; ogni cartella si riautorizza quando serve davvero (la prima volta che un'immagine o una nota ne ha bisogno) o in blocco da un'azione esplicita.
- **Build senza sandbox:** nessuna riautorizzazione necessaria per i file, ma macOS mostrerà di nuovo le richieste di «Files e cartelle» (Desktop, Documenti, Download) perché sono legate all'identificatore.
- Test da fare: apri un documento in una cartella nuova, poi uno già in un percorso importato; verifica che il pannello compaia una sola volta per cartella.

## 6. Associazioni di file e Launch Services

- **Tipi dichiarati:** PDF (`com.adobe.pdf`, classe `Owner`), Markdown (`net.daringfireball.markdown`, dichiarato in `UTImportedTypeDeclarations`) ed EPUB (`org.idpf.epub-container`). Gli identificatori dei tipi **non** cambiano con il Bundle ID; cambia solo chi dichiara di aprirli.
- **Oggi** le due app con lo stesso Bundle ID sono per Launch Services **la stessa app**: «Apri con» e il lettore predefinito possono puntare a una o all'altra copia. È una delle ragioni della separazione.
- **Dopo la separazione:** la nuova app va registrata (`lsregister` o la prima apertura), e per non rubare i PDF a Anteprima o a PageFlow conviene cambiare la classe del PDF da `Owner` a `Default`.
- **Lettore PDF predefinito:** l'associazione impostata dall'utente punta al vecchio identificatore e resta lì. L'avviso «Imposta Glossa come lettore predefinito» (`hasShownDefaultPDFPrompt`) deve ripartire per la nuova identità, e per questo la chiave non si importa.
- **Icone dei documenti** (`PDFDocument.icns`, `MarkdownDocument.icns`) e dichiarazione dell'icona del tipo Markdown seguono l'app nuova senza modifiche; la cache delle icone di Finder potrebbe richiedere `killall Finder` o un riavvio.
- Test: installare entrambe le app, aprire un PDF con «Apri con» da ciascuna, controllare che «Cambia tutto…» punti all'app scelta.

## 7. Strategia di rollback

Poiché nulla di PageFlow viene modificato, tornare indietro significa **smettere di usare i dati nuovi**.

| Situazione | Azione |
|---|---|
| L'importazione fallisce a metà | Si elimina solo `Glossa/.import-staging`; il marcatore non è stato scritto, quindi si può ripetere |
| L'utente non è soddisfatto dopo l'importazione | «Rimuovi i dati importati»: elimina il dominio nuovo e `Application Support/Glossa` **solo dopo conferma**, mai l'origine |
| Un errore di compatibilità della build nuova | Si riporta `PRODUCT_BUNDLE_IDENTIFIER` al vecchio valore: il dominio e le cartelle di PageFlow sono intatti |
| Dati nuovi scritti da una versione più recente | Si leggono in sola lettura; i colori hanno già questo comportamento (schema più nuovo non si sovrascrive) |

Altre salvaguardie:
- interruttore di funzione (`glossa.migration.enabled`) per spegnere l'importazione senza una nuova build;
- modalità «a secco» (§2);
- registro dettagliato con `os_log` (nessun dato personale nel testo);
- le copie di riserva già previste per i colori (`glossa.markup.layer.*.backup`) valgono anche dopo l'importazione.

## Decisioni ancora aperte

1. Il nuovo identificatore e la squadra di firma.
2. Se la build di distribuzione resta senza sandbox (importazione diretta) o passa al sandbox (riautorizzazioni).
3. Se importare di default `recentFiles` e `sessionRestore.v1` o solo su richiesta.
4. Il nome della cartella di Application Support nuova.
5. Se la classe del PDF scende da `Owner` a `Default`.

## Piano di realizzazione (non eseguito)

1. **Fase A** — nuovo identificatore, senza importazione; verificare i permessi e Launch Services.
2. **Fase B** — importazione delle preferenze (§2), con anteprima a secco e foglio di conferma.
3. **Fase C** — copia di Application Support (§3).
4. **Fase D** — file recenti, sessione e cartelle (§4–5).
5. **Fase E** — associazioni (§6) e documentazione per l'utente.

Struttura prevista: tipi puri e testabili con origine e destinazione iniettate (`LegacyImportPlan` con l'elenco consentito, `DefaultsImporter` con una sorgente simulata, `ApplicationSupportCopier` con una cartella radice temporanea), come già fatto per `MarkupPalette`/`PaletteStore`. Test minimi: l'elenco consentito, la destinazione che vince, l'idempotenza, la sorgente che resta identica byte per byte, l'interruzione a metà e la ripresa, i percorsi senza segnalibro, e l'assenza di scritture nelle chiavi di PageFlow.
