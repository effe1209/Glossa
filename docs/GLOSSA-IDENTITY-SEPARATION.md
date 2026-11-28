# Glossa: separazione dall'identità di PageFlow

Documento tecnico di migrazione. **Descrive un lavoro futuro**: nulla di quanto sotto è implementato, salvo la parte «Cosa è già stato fatto». **Aggiornamento (PR 4):** l'identificatore è ora `io.github.effe1209.Glossa` e l'importazione dalle preferenze di PageFlow è proposta esplicitamente (Importa / Non ora / Non importare mai); i percorsi di Application Support di PageFlow non sono toccati e la copia di Recovery, Attachments ed EPUB Annotations resta una fase separata. Il testo qui sotto è la pianificazione originale.

## Decisioni prese (28 novembre 2026)

1. **Identificatore:** `io.github.effe1209.Glossa`, definitivo.
2. **Build di riferimento:** `Release-Direct`, **non sandboxed**, firmata ad hoc. Un file `Local.xcconfig` non versionato permette di usare il proprio certificato gratuito `Apple Development` (Personal Team). Nessuna dipendenza da certificati o Team ID dell'autore originale (`V43797R8Q6` va tolto dal progetto). Nessuna pretesa di notarizzazione.
3. **Migrazione sempre esplicita**, con una finestra a tre scelte: *Importa*, *Non ora*, *Non importare mai*. «Importa» copia le preferenze consentite, le palette, i documenti recenti e i dati compatibili. `sessionRestore.v1` e `Recovery` solo con richieste separate, mai in automatico. Si copia, non si sposta e non si cancella nulla. I segnalibri con scope di sicurezza si verificano uno per uno.
4. **Application Support:** nuova cartella `Glossa`, copiando i dati necessari da `PageFlow`.
5. **Formati dei documenti:** si continuano a **leggere e scrivere** `<!-- pageflow-comments` (note Markdown) e `PageFlowType`/`pageflow-comment` (annotazioni PDF). Sono identificatori di formato, non branding. I documenti esistenti non si modificano.
6. **Intestazioni `// PageFlow` → `// Glossa`** nei sorgenti mantenuti dal progetto, in una PR separata. Il codice vendorizzato e i copyright originali non si toccano indiscriminatamente.
7. **Variabili d'ambiente:** `GLOSSA_*` come standard, `PAGEFLOW_*` come alias temporaneo. Se sono definite entrambe, vince `GLOSSA_*`.
8. **Classe PDF:** da `Owner` a `Default`: Glossa è un lettore PDF e non si dichiara proprietario del formato.

**Correzione allo stato descritto sotto.** Le build fatte con `CODE_SIGNING_ALLOWED=NO` (anche con lo scheme sandboxed) non incorporano gli entitlements e non sono sandboxed: tutti i dati stanno nei percorsi non sandboxed (`~/Library/Preferences/com.raccoontechnologies.PageFlow.plist`, `~/Library/Application Support/PageFlow`). La migrazione parte da lì.

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
- Le liste dei colori vecchie (`settings.highlightPresets`, `settings.underlinePresets`) sono **lasciate intatte** e lette una sola volta dalla migrazione dei colori (`PaletteStore.migrateIfNeeded`). Glossa non scrive mai in quelle chiavi. `settings.markupPaletteVersion` non è usata dal codice di Glossa (le palette vivono nei livelli `glossa.markup.layer.*.v1`): non viene letta e **non viene migrata**.
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

**Scelta.** Un identificatore DNS inverso su un dominio che controlli (`<dominio>.Glossa`), deciso una volta sola: dopo la pubblicazione non si cambia senza ripetere questa migrazione. È deciso: `io.github.effe1209.Glossa`.

**Cosa cambia con esso**
- `PRODUCT_BUNDLE_IDENTIFIER` nelle tre configurazioni del target (`project.pbxproj`). `Info.plist` lo legge da lì.
- Squadra di firma: il `DEVELOPMENT_TEAM` del progetto di origine è stato tolto (PR 2); la firma è ad hoc (`Config/Glossa-AdHoc.xcconfig`) e chi vuole il proprio certificato gratuito usa `Config/Local.xcconfig`. Per la distribuzione sul Mac App Store servirebbero un account a pagamento, un profilo e un record dell'app, fuori dagli obiettivi attuali.
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
- Si importano le chiavi `settings.*` che il codice usa davvero e che sono ammesse esplicitamente (tranne le sostituite da `glossa.*`), `documentViewStates.v2` e `bookmarks:*`. Una chiave `settings.*` non presente nell'elenco non si importa, qualunque sia il suo tipo (per esempio `settings.markupPaletteVersion`, che il codice non usa).
- Le liste dei colori vecchie si importano **così come sono** nelle chiavi vecchie del nuovo dominio, e poi la migrazione dei colori esistente (`PaletteStore`) le classifica: se coincidono con quelle di fabbrica o con `pastel-1` danno un livello vuoto, altrimenti diventano preset dell'utente accanto ai predefiniti Glossa.
- Non si importano: `hasShownDefaultPDFPrompt`, le chiavi `NS*` e le posizioni delle finestre, `sessionRestore.v1` (vedi §4).

**Regole**
- **La destinazione vince:** una chiave già presente nel nuovo dominio non si sovrascrive.
- **Marcatore:** `glossa.migration.fromPageFlow.v1` = `{data, versione dell'app, identificatore sorgente, chiavi importate}`. Scritto per ultimo; la sua presenza rende l'operazione idempotente.
- **Anteprima a secco:** una modalità che produce l'elenco delle chiavi che verrebbero importate senza scrivere nulla.
- **Dati non riconosciuti** (tipo o schema inattesi) si saltano e si registrano, mai si scartano nella sorgente.

**Comunicazione.** Un foglio al primo avvio: cosa verrà copiato (impostazioni, posizioni di lettura, colori, file recenti), «copia, non sposta», e tre scelte: «Importa», «Non ora» (si richiede dal menu e al prossimo avvio) e «Non importare mai» (scrive il marcatore con `skipped`). Un comando permanente nel menu: «Importa da PageFlow…».

## 3. Copia di Application Support, senza cancellare l'originale

**Stato dopo la PR 5.** Gli store di Recovery, Allegati e annotazioni EPUB usano solo `Application Support/Glossa/{Recovery, Attachments, EPUB Annotations}`, tramite `ApplicationSupportPaths`; non c'è nessun ripiego verso `PageFlow`. I dati di PageFlow si copiano soltanto con una scelta esplicita, come **unità B**, indipendente dalle preferenze (**unità A**) e proposta nella stessa finestra (Importa / Non ora / Non importare mai).

- **Copia, mai spostamento.** Nulla in `Application Support/PageFlow` viene modificato, rinominato o cancellato. Si copiano solo i file regolari e visibili, controllati prima (JSON del tipo che l'app salva e col nome che l'app darebbe loro; immagini che si aprono con ImageIO). Non validi, nascosti, link simbolici e sottocartelle sono saltati e riportati. I JSON oltre **64 MiB** non si copiano.
- **Staging e conflitti.** Ogni file passa da `Glossa/.import-staging-<runId>/`, si confronta lo SHA-256 con l'originale e si sposta al suo posto senza sostituire nulla. Se Glossa ha già un file con lo stesso nome **vince Glossa** (identico = contato come identico, diverso = conflitto riportato).
- **Marker autorevole:** `Glossa/.migration-appsupport-v1.json`, scritto atomicamente e per ultimo. Senza marker la copia non è completa: una copia interrotta lascia lo staging e viene riproposta al lancio successivo, senza ripresa silenziosa. Gli staging `.import-staging-*` (solo cartelle vere dentro `Glossa/`, mai link né nulla di PageFlow) si eliminano quando l'utente sceglie «Non importare mai» per i file (dopo aver salvato il rifiuto) o quando una nuova copia non trova file validi; mai dopo il marker, e mai guardando soltanto l'offerta. All'avvio un passo separato (`tidyOrphanStaging`, fuori dal thread principale) elimina gli staging anche senza offerta, ma solo se non c'è nulla da copiare, ci sono solo link o i file sono stati rifiutati, e solo se la cartella non è stata toccata da almeno un'ora (un'altra copia potrebbe essere in corso); con un'offerta, con un marker valido o non leggibile, in una build con sandbox non si elimina nulla. `evaluate()` e `status()` restano in sola lettura.
- **Rifiuti separati:** unità A `glossa.migration.fromPageFlow.declined.v1`, unità B `glossa.migration.appSupport.declined.v1`. L'unità B si propone anche a chi ha già importato le preferenze, ma non a chi ha scelto «Non importare mai» per le preferenze. «Non ora» non scrive nulla.
- **Allegati.** Oltre **500 MiB** di allegati (binari: 1 MiB = 1.048.576 byte) si chiede una conferma esplicita prima di copiare. Il calcolo è preventivo: somma le dimensioni dei file regolari con `lstat`, senza aprirne nessuno, quindi la domanda precede ogni lettura e ogni SHA-256; è un limite superiore, perché conta anche file che il controllo successivo può scartare, e si ripete sui soli file validi per quelli cresciuti nel frattempo. **Annullamento:** la copia può essere annullata dalla finestra; fino all'inizio dello spostamento nelle cartelle di Glossa l'arresto è pulito (staging eliminato, nessun marker, nessun file in `Glossa/`) e l'offerta si ripresenta; da quel punto la copia prosegue fino in fondo e l'esito dice cosa è stato fatto. **Cartelle che sono link:** se `Application Support/PageFlow`, o la cartella di una delle tre categorie, è un link simbolico, non lo si segue mai; se non resta nulla da offrire, la finestra e il menu lo dicono con un motivo dedicato invece di «nulla da copiare». I link assoluti nelle note non si riscrivono: `adoptFallbackImages` riconosce sia la cartella `Glossa/Attachments` sia `PageFlow/Attachments` (file regolare esistente, mai un link simbolico) e gli originali restano.
- **Restart.** Solo l'unità A richiede il riavvio controllato; la B no, perché la offerta viene prima che gli store Recovery e annotazioni vengano usati.
- **Recovery.** Le copie restano visibili anche in PageFlow, se lo si apre. Una copia già usata e rimossa in Glossa non torna: il marker rende la copia eseguibile una volta sola.

**Limite delle build con sandbox.** `Debug` e `Release` hanno il sandbox attivo e non possono leggere né il dominio delle preferenze né la cartella Application Support di PageFlow: non propongono l'importazione (né delle preferenze né dei file) e, se richiesta dal menu, ne spiegano il motivo. Gli entitlements non si modificano per aggirare il limite; l'importazione si fa con `Release-Direct`.

**Sorgente:** `~/Library/Application Support/PageFlow/{Recovery, Attachments, "EPUB Annotations"}` (o nel container se la build è con sandbox). **Destinazione:** `~/Library/Application Support/Glossa/…` (la cartella nuova va decisa insieme al nuovo identificatore).

**Metodo** (descrive l'implementazione: `AppSupportScanner`, `AppSupportMigrator`, `CombinedMigrationCoordinator`)
1. **Decisione, in sola lettura.** L'offerta conta i file regolari e visibili con `lstat`, senza aprirli. Distingue: nulla da copiare; cartella che è un link (mai seguito); cartella che esiste ma non si può leggere (permessi o elenco fallito), con un messaggio esplicito invece di «nulla da copiare». Se una sola categoria non è leggibile ma le altre sì, l'offerta resta e la finestra avverte che quella non verrà copiata. Nel corso della copia una categoria illeggibile (cartella o anche un solo file) non è «completata»: si copia ciò che si legge (in modo idempotente), ma **non si scrive il marker**, quindi la copia si ripropone a ogni avvio finché la cartella non torna leggibile; le categorie già copiate risultano allora identiche e non si copia due volte.
2. **Soglia allegati.** Oltre 500 MiB (somma delle dimensioni dal conteggio, quindi prima di aprire qualsiasi file) serve una conferma esplicita.
3. **Scansione e controllo.** Ogni file regolare si apre con `O_NOFOLLOW`, si calcola lo SHA-256 in streaming e si verifica che sia del tipo che l'app saprebbe leggere; i JSON oltre 64 MiB e i file non validi si saltano e si riportano.
4. **File già in Glossa e spazio libero.** I file che Glossa ha già (identici a quelli di PageFlow, come dopo una copia parziale, oppure diversi, e allora vince Glossa) si regolano subito, senza copiarli di nuovo, purché il file di PageFlow sia ancora com'era alla scansione (stessa dimensione e data; altrimenti segue il percorso normale con tutti i controlli). Lo spazio libero richiesto riguarda solo i file ancora da copiare: la loro somma più un decimo più 1 MiB; se non ne restano, non serve. La soglia dei 500 MiB non cambia.
5. **Staging.** Ogni file rimasto si copia con `FileManager.copyItem` in `Glossa/.import-staging-<runId>/<categoria>/`, si riconfronta lo SHA-256 con quello della scansione e si controlla che la sorgente non sia cambiata (dimensione e data) prima e dopo la copia.
6. **Spostamento file per file** dallo staging alla cartella di Glossa, con un rinomina che non sostituisce mai nulla. Se Glossa ha già un file con quel nome vince Glossa (identico o conflitto), e la copia in staging si scarta. Da qui in poi la copia non si può più annullare.
7. **Marker per ultimo,** scritto in modo atomico, solo se ogni file è contabilizzato e nulla era illeggibile (né una cartella né un singolo file). Tre situazioni distinte: **(a)** qualcosa non si può leggere (permessi): si copia il leggibile, nessun marker, nuovo tentativo al lancio successivo, con i file già copiati riconosciuti come identici; **(b)** ci sono file, tutti definitivamente non validi, e nulla di illeggibile: la migrazione è conclusa, il marker registra l'elenco degli invalidi e non si ripropone; **(c)** non c'è nessun file: nessun marker. Poi lo staging si elimina.
- **Nessuna ripresa silenziosa.** Una copia interrotta lascia lo staging e nessun marker; al lancio successivo si propone di nuovo e si riparte dall'inizio (i file già al loro posto risultano identici).
- **Nessun avanzamento a percentuale:** la finestra mostra «Importing…», può annullare fino al punto di non ritorno, poi «Finishing the import…».
- **Errore a metà:** se un file non si copia o non si verifica, non si scrive il marker, si elimina solo il proprio staging e l'offerta ritorna.
- **La sorgente** non si apre in scrittura e non cambia: permessi, date e attributi restano come sono.

**Per cartella**
- **`EPUB Annotations`**: si copia, perché evidenziazioni e note sono indicizzate per identità del libro. Controllo: JSON del tipo che l'app salva, con il nome che l'app darebbe.
- **`Attachments`**: si copia (immagini che ImageIO apre, PNG completo fino al chunk finale). I documenti dell'utente non si riscrivono mai: i link assoluti verso la cartella di PageFlow restano validi perché l'originale non si tocca, e `adoptFallbackImages` riconosce sia la cartella di Glossa sia quella di PageFlow.
- **`Recovery`**: si copia, con la stessa validazione (JSON di `MarkdownRecoveryStore` e nome `<UUID>.json`). Le note recuperate riappaiono nello stesso avvio. La cartella di destinazione si crea con permessi 0700. Se PageFlow è ancora aperto può riproporre le stesse copie (limite accettato).

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
| L'importazione fallisce a metà | Si eliminano solo gli `Glossa/.import-staging-*`; il marcatore non è stato scritto, quindi si può ripetere |
| L'utente non è soddisfatto dopo l'importazione | «Rimuovi i dati importati»: elimina il dominio nuovo e `Application Support/Glossa` **solo dopo conferma**, mai l'origine |
| Un errore di compatibilità della build nuova | Si riporta `PRODUCT_BUNDLE_IDENTIFIER` al vecchio valore: il dominio e le cartelle di PageFlow sono intatti |
| Dati nuovi scritti da una versione più recente | Si leggono in sola lettura; i colori hanno già questo comportamento (schema più nuovo non si sovrascrive) |

Altre salvaguardie:
- interruttore di funzione (`glossa.migration.enabled`) per spegnere l'importazione senza una nuova build;
- modalità «a secco» (§2);
- registro dettagliato con `os_log` (nessun dato personale nel testo);
- le copie di riserva già previste per i colori (`glossa.markup.layer.*.backup`) valgono anche dopo l'importazione.

## Stato dopo la PR 6: variabili d'ambiente e identificatori interni

**Variabili d'ambiente.** `GLOSSA_*` è il nome canonico, `PAGEFLOW_*` un alias temporaneo di compatibilità (da rimuovere in una versione successiva). La risoluzione sta in `AppEnvironment` (`PageFlow/Utilities/AppEnvironment.swift`), con l'ambiente iniettato nei test. Regole:
- decide la **presenza**, non il contenuto: se `GLOSSA_X` esiste, vince, anche se è vuota (il valore vuoto si restituisce com'è, senza ripiego sull'alias); `PAGEFLOW_X` conta solo se `GLOSSA_X` manca;
- per i controlli di sola presenza (`isSet`) basta una delle due;
- il rilevamento dei QA (`hasQAVariable`) guarda i nomi che iniziano per `GLOSSA_` o `PAGEFLOW_` e contengono `QA`;
- i nomi di `QA_*` (`QA_BACKGROUND`, `QA_PDF_URL`, `QA_OUTPUT_DIR`, `QA_PDF_MODE`, `QA_OPEN_DOCUMENT`, `QA_RESTORE_OPEN`, `QA_RUN_ID`, `QA_RECOVERY`, `QA_WINDOW_CLOSE`, `QA_WINDOW_CLOSE_SCENARIO`, `QA_SCENARIO`, `QA_DOC`, `QA_EXIT`) esistono solo nelle build Debug (`#if DEBUG`); le build Release non li contengono;
- in `Vendor/swift-markdown-engine` le tre variabili di tracciamento (`PERF_TRACE`, `SCROLL_TRACE`, `ANCHOR_TRACE`) sono lette con un alias minimo sul posto (il pacchetto non vede il target dell'app): basta una delle due. Il pacchetto resta per il resto invariato.
- Gli identificatori dei bundle dei cloni QA (`<id>.RecoveryQA.<runID>`, `<id>.RestoreQA.<runID>`) si accettano sia con `io.github.effe1209.Glossa` sia, come alias, con `com.raccoontechnologies.PageFlow`.

**Identificatori privati rinominati** (non persistiti, non scambiati con altri processi): label delle code (`io.github.effe1209.Glossa.markdown-recovery`, `…thumbnail-render`, `Glossa.MarkdownWikiLinkPresence`), identificatori di finestra e voce di menu (`GlossaUserCreatedWindow`, `Glossa.contextMenuPrefix`), notifiche interne (`Glossa.shortcutsDidChange`, `GlossaWindowDidFailToEnterFullScreen`), spazio di coordinate (`glossa.proximityField`), chiave di attributo temporanea (`GlossaPhysicalLineEnding`), prefisso dei file audio temporanei EPUB (`Glossa-EPUBAudio-`) e file di prova dei permessi (`.glossa-<uuid>`).

**Rimasto com'è di proposito:** sottosistema dei log `com.pageflow`, marker e chiavi dei formati dei documenti, pasteboard type e UTI `com.pageflow.*` del motore Markdown, schema `pageflow-epub`, cartelle di cache e temporanee del codice vendorizzato, percorsi temporanei delle prove QA (`pageflow-*-qa-…`, letti da script esterni) e la suite `pageflow.tests…` degli host di test. I simboli Swift `PageFlow*`/`pageFlow*` sono della PR 7.

## Piano di realizzazione, per PR piccole e indipendenti

Prima di ogni PR: build Debug, Release e Release-Direct e tutti i pacchetti di test. Al termine di ogni PR ci si ferma per la revisione.

1. **PR 1** — riferimenti visibili, Help e documentazione (nessun cambio di identificatore).
2. **PR 2** — firma gratuita: tolto il Team ID originale, configurazione ad hoc condivisa e `Local.xcconfig` non versionato.
3. **PR 3** — preparazione della migrazione (lettore della sorgente in sola lettura, elenco consentito, anteprima a secco, marcatore, test con dati simulati, hash della sorgente prima e dopo, rollback), senza cambiare l'identificatore.
4. **PR 4** — cambio dell'identificatore e attivazione della migrazione (finestra a tre scelte), invito per il lettore PDF predefinito e classe PDF `Default`.
5. **PR 5** — copia di Application Support (`Attachments`, `EPUB Annotations`; `Recovery` solo su richiesta) in `Glossa/`.
6. **PR 6** — identificatori interni (log, notifiche, code, chiavi di attributo) e variabili `GLOSSA_*` con alias `PAGEFLOW_*`.
7. **PR 7** — rinomina di classi e componenti Swift (`pageFlow*`, `PageFlowApp`, `PageFlowGlass*`).
8. **PR 8** — rinomina del progetto Xcode, target, schemi e cartella (in due passi: schemi/target/progetto, poi cartella dei sorgenti con i link dei test).
9. **PR separata** — intestazioni `// PageFlow` → `// Glossa` nei sorgenti del progetto (non nel codice vendorizzato).

Struttura prevista per la migrazione: tipi puri e testabili con origine e destinazione iniettate (`LegacyImportPlan` con l'elenco consentito, `DefaultsImporter` con una sorgente simulata, `ApplicationSupportCopier` con una cartella radice temporanea), come già fatto per `MarkupPalette`/`PaletteStore`. Test minimi: l'elenco consentito, la destinazione che vince, l'idempotenza, la sorgente identica byte per byte, l'interruzione a metà e la ripresa, i percorsi senza segnalibro, e l'assenza di scritture nelle chiavi di PageFlow.

**Finestra delle autorizzazioni (PR 5, fase 8).** All'avvio la finestra «Allow Files and Folders» compare anche quando c'è un'offerta di importazione: dopo che la finestra modale dell'offerta si è chiusa (non si sovrappongono) e solo se l'app non si sta riavviando. Se l'offerta viene rimandata, l'elenco compare comunque, una sola volta; il menu lo riapre sempre.
