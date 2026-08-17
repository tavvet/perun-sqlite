# perun-sqlite: техническая карта проекта

Дата среза: 2026-07-09.

Этот документ не заменяет `README.md`. Его задача — быстро объяснить устройство кода, основные
потоки выполнения, границы модулей и места, важные для дальнейшего review/refactoring.

## Назначение

`perun-sqlite` — низкоуровневый SQLite driver для Swift/Perun. Это тонкая типизированная обёртка
над `libsqlite3` на async/await. Он **зеркалит публичную поверхность** PostgreSQL-сиблинга
[perun-pgsql](../perun-pgsql) везде, где это осмысленно для встраиваемого движка, и реализует:

- открытие БД (`sqlite3_open_v2`), файл / `:memory:` / URI, read-only, PRAGMA-конфиг;
- параметризованные запросы (`?`-плейсхолдеры), мультистейтмент, prepared statements;
- типизированное декодирование строк/ячеек через `SQLiteValue` (5 storage-классов);
- ленивое построчное streaming через `sqlite3_step`;
- транзакции (`BEGIN`/`COMMIT`/`ROLLBACK`, DEFERRED/IMMEDIATE/EXCLUSIVE);
- ленивый bounded connection pool с ресайклингом;
- отмену/дедлайны через `sqlite3_interrupt` (`withTimeout`);
- типизированные ошибки (`SQLiteResultCode`, основной + extended код);
- extras: data-change hooks (`sqlite3_update_hook`), online backup (`sqlite3_backup_*`),
  пользовательские SQL-функции (`sqlite3_create_function_v2`).

Публичная библиотека: `PerunSQLite`. Демо-продукт: `perun-sqlite-demo`.

## Package Layout

```text
Package.swift
Sources/
  CSQLite/
    module.modulemap
    shim.h
  PerunSQLite/
    SQLiteConnection.swift
    SQLiteClient.swift
    Value.swift
    Result.swift
    Encoding.swift
    Errors.swift
    Statement.swift
    RowStream.swift
    Timeout.swift
    Concurrency.swift
    Hooks.swift
    Backup.swift
    Functions.swift
    Types/
      SQLiteDecodable.swift
      ScalarTypes.swift
      FoundationTypes.swift
      JSON.swift
  PerunSQLiteDemo/
    Demo.swift
Examples/
Tests/PerunSQLiteTests/
```

## Target Map

### `CSQLite`

System library target, экспонирующий `libsqlite3` в Swift.

- `shim.h` подключает `<sqlite3.h>`. Почти весь API SQLite — настоящие функции (в отличие от
  OpenSSL), поэтому шим только вносит заголовок в Clang-модуль.
- `SQLITE_TRANSIENT` (`(sqlite3_destructor_type)-1`) — cast-макрос, невидимый импортёру Swift;
  пересобирается в `Concurrency.swift` через `unsafeBitCast`.
- `Package.swift` находит SQLite через `pkgConfig: "sqlite3"` + `providers` (brew/apt). На macOS
  заголовок и библиотека берутся из SDK — сборка из коробки; на Linux нужен `libsqlite3-dev`.

### `PerunSQLite`

Главный таргет. Core design:

- `SQLiteConnection` — `actor`, владеет одним `sqlite3 *`.
- Все вызовы libsqlite3 идут на выделенной serial `DispatchQueue` через `withBlockingIO`, чтобы
  блокирующий `sqlite3_step` (может ждать на busy-локе) не занимал кооперативный пул.
- Драйвер возвращает `QueryResult`, `SQLiteRow`, `SQLiteCell`, несущие `SQLiteValue`.

### `PerunSQLiteDemo` / `PerunSQLiteExamples`

Запускаемые программы, демонстрирующие весь путь против `:memory:`/временного файла. **Внешний
сервер не нужен** (в отличие от perun-pgsql).

## Отличия от perun-pgsql

PostgreSQL — клиент-серверный: сокеты, wire-протокол, аутентификация, TLS, текст/бинарь-форматы,
OID типов, фоновый reader с пайплайнингом. SQLite — встраиваемый, поэтому весь транспортный низ
отсутствует.

Зеркалим (публичный API): `SQLiteConnection`/`SQLiteClient`, `SQLiteRow`/`SQLiteCell`/`QueryResult`/
`ColumnMetadata`, `SQLiteDecodable`/`SQLiteEncodable`, `PerunError`/`SQLiteError`/`SQLiteResultCode`,
`queryStream`, `withTransaction`, `PreparedStatement`, `withTimeout`, `withBlockingIO`.

Выкинули (нет аналога): `Wire/`, `Auth/` (SCRAM/SASLprep), `Crypto/*`, `Socket/`, `TLS/`, COPY,
wire-пайплайнинг (`pipeline*`), массивы, `TemporalTypes`/`NetworkTypes` (interval/time/inet),
LISTEN/NOTIFY (заменён change-hooks), `PostgresFormat`/`PostgresOID`, `cancelCurrentQuery`
(заменён на `sqlite3_interrupt`).

Заменили на нативные SQLite-фичи: COPY → online backup; LISTEN/NOTIFY → data-change hooks; плюс
custom SQL functions (аналога в pgsql нет).

## Core Runtime Model

```text
Application code
    |
    v
SQLiteClient actor           (опционально — пул)
    |
    | acquire/release
    v
SQLiteConnection actor
    |
    | withBlockingIO(on: ioQueue)   -- сериализует C-вызовы
    v
libsqlite3 (blocking C)
```

`SQLiteConnection` — центральный объект. Владеет:

- `handle: SQLiteHandle` (боксированный `sqlite3 *`);
- serial `ioQueue`;
- реестром prepared-стейтментов `[UInt64: StatementHandle]`;
- состоянием стримов `[UInt64: StreamState]`;
- generation-счётчиками для отмены (`currentOpGeneration`/`runningOpGeneration`);
- контекстом транзакции (`activeTransactionContext`);
- change-hook стримом (`dataChanges` + continuation + retained box).

## Модель конкурентности (важно)

- `SQLiteConnection` — actor: сериализует **каждый отдельный** вызов.
- C-указатели (`sqlite3 *`, `sqlite3_stmt *`) не `Sendable`. Они оборачиваются в
  `SQLiteHandle`/`StatementHandle` (`final class … @unchecked Sendable`, `Concurrency.swift`).
  `@unchecked` обоснован инвариантом: **все** вызовы libsqlite3 для соединения идут на его
  единственной serial `ioQueue`, поэтому указатель никогда не трогается конкурентно. В
  `withBlockingIO`-замыкания захватываются только эти боксы (локальный `let db = handle` на акторе),
  никогда `self.*`.
- **Флаг `SQLiteHandle.closed`** закрывает окно use-after-free между `close()` и in-flight
  операцией: `isClosed`/`ensureOpen()` живёт на акторе и не упорядочен против освобождения хендла на
  `ioQueue`. Поэтому `closed` ставится **на `ioQueue`** прямо перед `sqlite3_close_v2`, а каждый
  ioQueue-блок, разыменовывающий `db.db` без stmt-гварда, сначала проверяет `guard !db.closed` —
  проверка сериализована с close на той же очереди.
- **Нет отдельного wire-lock** (в отличие от pgsql): у SQLite нет общего провода и пайплайнинга.
  Соединение рассчитано на **одну логическую задачу за раз**: не запускать другие запросы на том же
  соединении во время `withTransaction`/`queryStream`. Для конкурентности — пул (`SQLiteClient`),
  который выдаёт каждой задаче своё соединение. Это идиоматичная модель SQLite (ср. DatabaseQueue vs
  DatabasePool в GRDB).

## Connection Lifecycle

### Open — `SQLiteConnection.connect(_:)`

1. Выделить serial `ioQueue`.
2. На очереди: `sqlite3_open_v2` с флагами (readonly / readwrite+create / URI), затем
   `sqlite3_extended_result_codes(db, 1)` (чтобы коды несли extended-детализацию).
3. Создать актор, применить конфиг (`applyConfiguration`): `busy_timeout`, `PRAGMA journal_mode`,
   `PRAGMA foreign_keys`, и — если `observeDataChanges` — установить update-hook.
4. При ошибке конфигурации — `close()` и проброс.

### `SQLiteConfiguration`

`path`, `readonly`, `create`, `enableForeignKeys` (default on), `journalMode`, `busyTimeout`
(default 5s), `enableURIFilenames`, `observeDataChanges`. Фабрики `.memory()`, `.file(_:…)`.

### Close — `close()`

Идемпотентно: снять update-hook (до освобождения box), финализировать все prepared-стейтменты и
стримы, поставить `db.closed = true` (на `ioQueue`, перед освобождением), `sqlite3_close_v2`,
завершить change-стрим, обнулить box.

### `deinit` — safety net

Если соединение (или пул без `shutdown()`) брошено без `close()`, `deinit` дублирует уборку
`close()`: завершает change-стрим и на `ioQueue` финализирует стейтменты + `sqlite3_close_v2`, иначе
утекли бы `sqlite3 *`, файловый дескриптор, компилированные стейтменты и FunctionBox'ы. Зеркалит
`deinit` из `PostgresConnection`. На деструкции других ссылок нет, поэтому гонок с in-flight-операцией
не бывает.

## Query Execution

Все запросы исполняются в одном блоке `withBlockingIO` на `ioQueue`.

### Мультистейтмент — `query(_ sql:)`

`perunRunMultiStatement`: цикл `sqlite3_prepare_v2` по `tail`-указателю, каждый оператор степается до
`SQLITE_DONE`, возвращается **последний** result-set. Аналог simple-query pgsql. Каждый оператор —
свой autocommit (не атомарно между собой; для атомарности — `withTransaction`).

`rowsAffected` считается через `perunRowsAffected` (`sqlite3_stmt_readonly`): для read-only оператора
(`SELECT`) — `0` (иначе он отражал бы `sqlite3_changes` предыдущего DML), для DML (в т.ч.
`INSERT…RETURNING`, который не read-only) — реальное число изменённых строк.

### Параметризованный — `query(_ sql:_ parameters:)`

`perunRunSingleStatement`: **ровно один** оператор, биндинг параметров, степпинг, сбор строк.
Компиляция идёт через `perunCompileSingle`, который отвергает «хвост» (второй оператор после `;`) как
`PerunError.multipleStatements` — иначе он молча терялся бы (в отличие от мультистейтментного
`query(_:)`). То же для `prepare`/`queryStream`. Whitespace/комментарий в хвосте — не оператор.

### Биндинг — `perunBindParameters`

Позиционный (`?1…?n`). Проверка числа параметров → `PerunError.parameterCountMismatch`. `nil`
элемент → `sqlite3_bind_null`. По `SQLiteValue`: `bind_null`/`bind_int64`/`bind_double`/`bind_text`
(точная длина в байтах, `SQLITE_TRANSIENT` — SQLite копирует)/`bind_blob` (TRANSIENT).

### Чтение строки — `perunReadRow`

По `sqlite3_column_type`: INTEGER→`.integer(column_int64)`, FLOAT→`.real(column_double)`,
TEXT→`.text` (по точной длине `column_bytes` + `column_text`, декод UTF-8), BLOB→`.blob`, иначе
`.null`. Метаданные (`perunColumnMetadata`): `column_name` + `column_decltype` (nil для выражений).

### Prepared statements

- `prepare(_:)` → компиляция, чтение метаданных и `bind_parameter_count`, сохранение
  `StatementHandle` в реестр, возврат `PreparedStatement { id, sql, parameterCount, columns,
  connectionID }`.
- `execute(_:_:)` → `reset`+`clear_bindings`, биндинг, степпинг, `reset` (стейтмент переиспользуем).
- `closePrepared(_:)` → `sqlite3_finalize` + удаление из реестра.
- Скоупинг: `execute`/`closePrepared` проверяют `connectionID` → `preparedStatementConnectionMismatch`.

### Streaming — `queryStream`

Возвращает `SQLiteRowStream` (`AsyncSequence` of `SQLiteRow`). `sqlite3_step` — это и есть курсор,
так что streaming здесь нативен. Компилированный stmt хранится в `streams[generation]`;
`nextStreamRow` делает один `step` на очереди (ROW→строка, DONE→финализация+nil, error→финализация+
throw). `StreamCleanup.deinit` финализирует брошенный стрим; guard по generation
(`streams.removeValue`) делает повторный вызов no-op. **Дивергенция от pgsql**: эксклюзивная
блокировка не нужна — actor сериализует шаги (см. «Модель конкурентности»).

### Transactions — `withTransaction(kind:_:)`

`BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE]` → тело со вложенным `Transaction` (query/prepare/execute/
closePrepared) → `COMMIT` на успехе, `ROLLBACK` на throw. BEGIN/COMMIT/ROLLBACK исполняются
**непрерываемо** (`_execUninterruptible`, без cancellation-обёртки), поэтому таймаут-транзакция
корректно откатывается, а не остаётся открытой. `Transaction` защищён `contextID`: использование
хендла вне scope → `invalidTransactionContext`.

## Отмена, interrupt, timeout

`runCancellable` оборачивает блокирующую операцию: `withTaskCancellationHandler` → на отмену
`Task { interruptIfRunning(generation:) }` → `sqlite3_interrupt(db)` (потокобезопасен), после чего
`sqlite3_step` возвращает `SQLITE_INTERRUPT`, а вызывающий получает `CancellationError`.
Generation-guard (`runningOpGeneration == generation`) не даёт поздней отмене задеть следующую
операцию — аналог `currentRead === op` в pgsql. `withTimeout` (`Timeout.swift`) — verbatim из pgsql:
гонка операции против `Task.sleep`; на таймаут операция отменяется (interrupt + drain), соединение
остаётся пригодным, бросается `PerunError.timedOut`.

## Pool — `SQLiteClient`

Почти дословное зеркало `PostgresClient`: ленивый bounded-пул, `withConnection`/`query`/
`withTransaction`/`shutdown`/`connectionCount`, waiters с cancellation-aware хэндшейком, recycling
(`maxConnectionLifetime`/`maxIdleTime` + reaper), vet-on-borrow. Правки под SQLite:

- на release соединение отбрасывается, если `await connection.isInTransaction`
  (`sqlite3_get_autocommit == 0`);
- `isProbablyAlive` тривиален (открытый handle);
- классификация ошибок для discard — `PerunError.shouldDiscardConnection` (см. ниже).

Нюансы конкурентности (в README и в докстроке): для читателей нужен WAL (`journalMode: .wal`);
`:memory:` приватен на соединение — для пула in-memory нужен shared-cache URI
(`file::memory:?cache=shared`, `enableURIFilenames`).

## Error Model

- `SQLiteResultCode` (`Errors.swift`) — типизированный код (аналог `SQLState`): основные коды
  (ok/error/busy/locked/readonly/corrupt/constraint/…) и extended (`constraintUnique`/`ForeignKey`/
  `NotNull`/`PrimaryKey`/`Check`/…, `busySnapshot`), `.other(Int32)`. `init(code:)`/`code` заданы
  числовыми литералами (с комментом `SQLITE_*`), т.к. часть extended-макросов — выражения
  `(primary | (sub<<8))`, невидимые импортёру. Хелперы: `primaryCode`, `isConstraintViolation`
  (primary==19), `isBusy` (5/6).
- `SQLiteError { resultCode; extendedCode; message }` из `sqlite3_extended_errcode`/`sqlite3_errmsg`
  — аналог `PostgresServerError`.
- `PerunError` (урезанный зеркальный enum, `Equatable`): `connectionFailed`, `connectionClosed`,
  `sqlite(SQLiteError)`, `unexpectedNull`, `columnNotFound`, `decodingFailed`,
  `parameterCountMismatch`, `multipleStatements`, `preparedStatementConnectionMismatch`,
  `invalidTransactionContext`, `clientShutdown`, `timedOut`. Плюс `sqliteError` accessor и
  `shouldDiscardConnection` — исчерпывающий switch (аналог `mayHaveDesynchronizedWire`). **Важно**:
  классификация sqlite-ошибок идёт по **primary-коду** (`primaryCode ∈ {7,10,11,14,26}` = NOMEM/
  IOERR/CORRUPT/CANTOPEN/NOTADB), а не по именованным кейсам: extended-коды включены, поэтому реальная
  I/O/corruption-ошибка приходит как `.other(266)` и по именам не поймалась бы. `SQLiteError` тоже
  `Equatable`.

## Type System

Декодинг — `SQLiteDecodable { static func decode(from: SQLiteValue) throws -> Self }`; энкодинг —
`SQLiteEncodable { func encode() -> SQLiteValue }`. NULL обрабатывается в `SQLiteCell.decode`
(бросает `unexpectedNull`), `decodeIfPresent` возвращает nil.

Скаляры (`ScalarTypes.swift`): Bool, Int/Int16/Int32/Int64, Float, Double, String, `[UInt8]` (blob).
Целые декодятся из INTEGER (range-checked через `T(exactly:)`), REAL (только точное целое), TEXT
(base-10). Коэрсинг в духе SQLite, но строгий (3.5→Int бросает).

Foundation (`FoundationTypes.swift`): `Data`↔blob; `UUID`↔TEXT(uuidString) или blob(16);
`Date`→TEXT ISO-8601 (декод из TEXT/INTEGER-unix/REAL-julian; civil-days арифметика перенесена из
perun-pgsql). Текстовый парсер `parseSQLiteDate` терпим к формам `datetime()`: `HH:MM` без секунд,
компактное смещение `±HHMM` без двоеточия, «лишние» дробные цифры сверх 9. `Decimal`↔TEXT (точность).
`SQLiteJSON` (`JSON.swift`) — тонкая TEXT-обёртка. `SQLiteValue` сам `SQLiteEncodable` — escape hatch
для точного контроля storage-класса.

`ColumnMetadata`/`SQLiteCell`/`SQLiteRow`/`QueryResult` — `Equatable` (удобно для тестов; возможно,
т.к. `SQLiteValue` уже `Equatable`). `QueryResult.first` — шорткат к первой строке.

## Extras

- **Hooks** (`Hooks.swift`): `SQLiteChange { operation(.insert/.update/.delete); database; table;
  rowID }`, `nonisolated let dataChanges: AsyncStream<SQLiteChange>`. `installChangeHooks` ставит
  `sqlite3_update_hook` с `@convention(c)`-замыканием без захвата; контекст — `passUnretained` box,
  живущий пока актор держит `changeHookBox` (снимается до освобождения в `close`). Локальный аналог
  LISTEN/NOTIFY.
- **Backup** (`Backup.swift`): `backup(to:sourceName:destinationName:)` через
  `sqlite3_backup_init/step(-1)/finish` на очереди источника; получает handle назначения через
  внутренний `rawHandle()`. Контракт (нельзя полностью проверить между двумя соединениями):
  назначение должно быть **эксклюзивно** во время бэкапа (иначе две очереди трогают один `sqlite3 *`
  — безопасно только в serialized-режиме SQLite). Best-effort гвард `!source.closed && !dest.closed`
  на очереди сужает окно закрытия.
- **Functions** (`Functions.swift`): `createFunction(_:argumentCount:deterministic:_:)`
  (`argumentCount: Int?`, `nil` = variadic) через `sqlite3_create_function_v2`. `argumentCount`
  валидируется (`nil` или `0…127`, иначе `invalidArgumentCount` — вне диапазона это UB в C и трап
  `Int32.init`). Ошибка регистрации формируется **внутри** блока `ioQueue` (не после хопа на актор,
  где конкурентный `close()` мог бы освободить handle). xFunc/xDestroy — `@convention(c)`-замыкания
  без захвата, зовущие глобальные хелперы; замыкание пользователя — в `FunctionBox` (`passRetained`,
  освобождается xDestroy при close/replace/ошибке регистрации). Аргументы читаются из
  `sqlite3_value_*`, результат — `sqlite3_result_*` (пустой blob — через непустой sentinel, как в
  бинде); throw → `sqlite3_result_error`.

## Tests

Весь набор (`Tests/PerunSQLiteTests/`) гоняется **офлайн против `:memory:`** (и временных файлов для пула/
бэкапа) — никакого integration-гейта.

- `SmokeTests` — базовые инварианты `SQLiteValue`/`SQLiteResultCode`.
- `TypeTests` — декод/энкод скаляров и Foundation (Date во всех трёх конвенциях, UUID, Decimal,
  JSON), round-trip через БД, `declaredType`.
- `ErrorClassificationTests` — round-trip кодов, class-хелперы, `shouldDiscardConnection`,
  `parameterCountMismatch`, скоупинг prepared-стейтментов.
- `ConnectionTests` — create/insert/select, NULL/`decodeIfPresent`, типизированная constraint-ошибка
  и пригодность соединения после неё, prepared, транзакции (commit+rollback), streaming (+early
  break), blob/bool/date.
- `PoolTests` — общие данные через пул (WAL-файл), конкурентные чтения, атомарность транзакции,
  shutdown, lifetime-ресайклинг.
- `ExtrasTests` — custom functions (+throw), data-change hooks, online backup, timeout через
  interrupt.
- `RegressionTests` — фиксы из ревью: пустой blob → пустой BLOB (не NULL); отклонение
  мультистейтмента в single-путях; фабрика `.uri` + shared-cache in-memory; консистентность после
  drop без `close()` (safety-net `deinit`).

## Local Verification

```bash
swift test            # весь набор, без внешнего сервера
swift run perun-sqlite-demo       # end-to-end тур
swift build                       # библиотека + demo + examples (компилируемая проверка примеров)
```

Наблюдаемо: 69 тестов зелёные; демо проходит целиком (schema/params/typed select/transaction/
prepared/stream/function/hook/backup/pool).

## Where To Start When Changing Things

- Запрос/биндинг/чтение строк: `SQLiteConnection.swift` (free-хелперы `perun*`), `Value.swift`.
- Декодинг типов: `Types/SQLiteDecodable.swift`, `Types/ScalarTypes.swift`,
  `Types/FoundationTypes.swift`, `TypeTests.swift`.
- Пул/транзакции: `SQLiteClient.swift`, `SQLiteConnection.withTransaction`/`isInTransaction`,
  `PoolTests.swift`.
- Отмена/таймауты: `runCancellable`/`interruptIfRunning` в `SQLiteConnection.swift`, `Timeout.swift`.
- C-интероп и Sendable-боксы: `Concurrency.swift`, `CSQLite/`.
- Extras: `Hooks.swift`, `Backup.swift`, `Functions.swift`.
```
