package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"html/template"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
)

const (
	KindMovie  = "movie"
	KindSeries = "series"

	RoleUser  = "user"
	RoleAdmin = "admin"

	MaxTelegramText = 3900
)

type Config struct {
	BotToken       string
	AdminIDs       map[int64]bool
	WorkerBaseURL  string
	Port           string
	DBPath         string
	HashSecret     string
	LinkTTL        time.Duration
	LinkMode       string
	MaxSeriesLinks int
	DefaultLang    string
	LogLevel       slog.Level

	WebtorEnabled           bool
	WebtorAPIBaseURL        string
	WebtorTimeout           time.Duration
	WebtorRewriteExportBase string
	WebtorAPIKey            string
	WebtorAPIToken          string

	SearchEnabled      bool
	SearchMaxResults   int
	TorrentRSSURLs     []string
	AllowedTorrentHosts map[string]bool
}

type App struct {
	cfg    Config
	log    *slog.Logger
	bot    *tgbotapi.BotAPI
	store  *Store
	server *http.Server

	shutdownOnce sync.Once
}

type User struct {
	ID             int64
	ChatID         int64
	Username       string
	FirstName      string
	LastName       string
	LanguageCode   string
	LanguageLocked bool
	Role           string
	IsBanned       bool
	CreatedAt      string
	UpdatedAt      string
	LastSeenAt     string
}

type Content struct {
	ID            int64
	Kind          string
	Title         string
	Normalized    string
	OriginalTitle string
	Year          int
	Overview      string
	PosterURL     string
	Language      string
	CreatedBy     int64
	CreatedAt     string
	UpdatedAt     string
}

type MediaItem struct {
	ID           int64
	ContentID    int64
	Season       int
	Episode      int
	EpisodeTitle string
	Quality      string
	AudioLang    string
	SubtitleLang string
	SourceURL    string
	SizeBytes    int64
	CreatedAt    string
}

type ExternalCandidate struct {
	ID        int64
	Provider  string
	Title     string
	Kind      string
	Year      int
	Quality   string
	SourceURL string
	InfoURL   string
	SizeBytes int64
	Seeders   int
	CreatedBy int64
	CreatedAt string
}

type SearchResult struct {
	Content      Content
	Score        int
	Exact        bool
	MatchedAlias string
}

type TokenInfo struct {
	Token     string
	ExpiresAt string
	CreatedAt string
	UsedAt    string
	Hits      int64
	UserID    int64
	Content   Content
	Media     MediaItem
}

type Store struct {
	db *sql.DB
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "configuration error: %v\n", err)
		os.Exit(1)
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	logger.Info("starting qooq cinema bot", "db", cfg.DBPath, "worker_base_url", cfg.WorkerBaseURL, "port", cfg.Port)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	app, err := NewApp(ctx, cfg, logger)
	if err != nil {
		logger.Error("failed to initialize app", "error", err)
		os.Exit(1)
	}
	defer app.Close()

	if err := app.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("app stopped with error", "error", err)
		os.Exit(1)
	}
}

func loadConfig() (Config, error) {
	cfg := Config{
		BotToken:       strings.TrimSpace(os.Getenv("BOT_TOKEN")),
		WorkerBaseURL:  strings.TrimRight(firstNonEmpty(os.Getenv("WORKER_BASE_URL"), os.Getenv("BASE_URL"), "http://localhost:8080"), "/"),
		Port:           firstNonEmpty(os.Getenv("PORT"), "8080"),
		DBPath:         firstNonEmpty(os.Getenv("DB_PATH"), "./qooq-cinema.db"),
		HashSecret:     strings.TrimSpace(os.Getenv("HASH_SECRET")),
		LinkMode:       strings.ToLower(firstNonEmpty(os.Getenv("LINK_MODE"), "landing")),
		MaxSeriesLinks: mustAtoi(firstNonEmpty(os.Getenv("MAX_SERIES_LINKS"), "80"), 80),
		DefaultLang:    normalizeLang(firstNonEmpty(os.Getenv("DEFAULT_LANG"), "es")),
		LogLevel:       parseLogLevel(firstNonEmpty(os.Getenv("LOG_LEVEL"), "INFO")),
		AdminIDs:       parseAdminIDs(os.Getenv("ADMIN_IDS")),

		WebtorEnabled:           parseBool(firstNonEmpty(os.Getenv("WEBTOR_ENABLED"), "false")),
		WebtorAPIBaseURL:        strings.TrimRight(firstNonEmpty(os.Getenv("WEBTOR_API_BASE_URL"), "http://127.0.0.1:8080/rest-api"), "/"),
		WebtorRewriteExportBase: strings.TrimRight(os.Getenv("WEBTOR_REWRITE_EXPORT_BASE"), "/"),
		WebtorAPIKey:            strings.TrimSpace(os.Getenv("WEBTOR_API_KEY")),
		WebtorAPIToken:          strings.TrimSpace(os.Getenv("WEBTOR_API_TOKEN")),

		SearchEnabled:       parseBool(firstNonEmpty(os.Getenv("SEARCH_ENABLED"), "true")),
		SearchMaxResults:    mustAtoi(firstNonEmpty(os.Getenv("SEARCH_MAX_RESULTS"), "6"), 6),
		TorrentRSSURLs:      splitCSV(os.Getenv("TORRENT_RSS_URLS")),
		AllowedTorrentHosts: parseHostSet(os.Getenv("ALLOWED_TORRENT_HOSTS")),
	}

	if cfg.BotToken == "" {
		return cfg, errors.New("BOT_TOKEN is required")
	}
	if cfg.HashSecret == "" {
		secret, err := randomBase64(32)
		if err != nil {
			return cfg, fmt.Errorf("generating temporary HASH_SECRET: %w", err)
		}
		cfg.HashSecret = secret
		fmt.Fprintln(os.Stderr, "WARNING: HASH_SECRET is empty. A temporary secret was generated; old links will be invalid after restart.")
	}
	if cfg.LinkMode != "landing" && cfg.LinkMode != "redirect" && cfg.LinkMode != "json" {
		return cfg, errors.New("LINK_MODE must be landing, redirect or json")
	}
	if cfg.MaxSeriesLinks < 1 {
		cfg.MaxSeriesLinks = 80
	}

	linkTTL := firstNonEmpty(os.Getenv("LINK_TTL"), "24h")
	ttl, err := time.ParseDuration(linkTTL)
	if err != nil {
		return cfg, fmt.Errorf("invalid LINK_TTL %q: %w", linkTTL, err)
	}
	cfg.LinkTTL = ttl

	webtorTimeout := firstNonEmpty(os.Getenv("WEBTOR_TIMEOUT"), "4m")
	wt, err := time.ParseDuration(webtorTimeout)
	if err != nil {
		return cfg, fmt.Errorf("invalid WEBTOR_TIMEOUT %q: %w", webtorTimeout, err)
	}
	cfg.WebtorTimeout = wt
	if cfg.WebtorRewriteExportBase == "" && cfg.WebtorEnabled {
		// Si Webtor fue iniciado con DOMAIN=$WORKER_BASE_URL, no hace falta reescritura.
		// Si DOMAIN quedó como localhost, puedes forzarla con WEBTOR_REWRITE_EXPORT_BASE.
		cfg.WebtorRewriteExportBase = ""
	}
	return cfg, nil
}

func NewApp(ctx context.Context, cfg Config, log *slog.Logger) (*App, error) {
	db, err := sql.Open("sqlite", cfg.DBPath)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	store := &Store{db: db}
	if err := store.Migrate(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate database: %w", err)
	}

	bot, err := tgbotapi.NewBotAPI(cfg.BotToken)
	if err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("telegram bot api: %w", err)
	}

	app := &App{cfg: cfg, log: log, bot: bot, store: store}
	app.server = &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           app.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	return app, nil
}

func (a *App) Run(ctx context.Context) error {
	a.log.Info("telegram bot authorized", "username", a.bot.Self.UserName)

	serverErr := make(chan error, 1)
	go func() {
		a.log.Info("http server listening", "addr", a.server.Addr)
		if err := a.server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
			return
		}
		serverErr <- nil
	}()

	updates := tgbotapi.NewUpdate(0)
	updates.Timeout = 30
	updateChan := a.bot.GetUpdatesChan(updates)

	for {
		select {
		case <-ctx.Done():
			a.bot.StopReceivingUpdates()
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = a.server.Shutdown(shutdownCtx)
			return ctx.Err()
		case err := <-serverErr:
			if err != nil {
				return fmt.Errorf("http server: %w", err)
			}
			return nil
		case update := <-updateChan:
			go a.safeHandleUpdate(ctx, update)
		}
	}
}

func (a *App) Close() {
	a.shutdownOnce.Do(func() {
		if a.store != nil && a.store.db != nil {
			if err := a.store.db.Close(); err != nil {
				a.log.Warn("closing database", "error", err)
			}
		}
	})
}

func (a *App) safeHandleUpdate(parent context.Context, update tgbotapi.Update) {
	ctx, cancel := context.WithTimeout(parent, 90*time.Second)
	defer cancel()
	defer func() {
		if r := recover(); r != nil {
			a.log.Error("panic while handling update", "recover", r)
		}
	}()

	if err := a.handleUpdate(ctx, update); err != nil {
		a.log.Error("update failed", "update_id", update.UpdateID, "error", err)
	}
}

func (a *App) handleUpdate(ctx context.Context, update tgbotapi.Update) error {
	if update.CallbackQuery != nil {
		return a.handleCallback(ctx, update.CallbackQuery)
	}
	if update.Message != nil {
		return a.handleMessage(ctx, update.Message)
	}
	return nil
}

func (a *App) handleMessage(ctx context.Context, msg *tgbotapi.Message) error {
	if msg.From == nil || msg.Chat == nil {
		return nil
	}
	user, err := a.ensureUser(ctx, msg.From, msg.Chat.ID, msg.Text)
	if err != nil {
		return err
	}
	if user.IsBanned {
		return a.sendText(ctx, msg.Chat.ID, a.tr(user.LanguageCode, "banned"), nil)
	}

	text := strings.TrimSpace(msg.Text)
	if text == "" {
		return nil
	}

	if msg.IsCommand() {
		cmd := strings.ToLower(msg.Command())
		args := strings.TrimSpace(msg.CommandArguments())
		switch cmd {
		case "start":
			return a.cmdStart(ctx, msg.Chat.ID, user)
		case "help":
			return a.cmdHelp(ctx, msg.Chat.ID, user)
		case "lang", "language", "idioma":
			return a.cmdLang(ctx, msg.Chat.ID, user, args)
		case "admin":
			return a.cmdAdmin(ctx, msg.Chat.ID, user)
		case "addmovie":
			return a.cmdAddMovie(ctx, msg.Chat.ID, user, args)
		case "addserie", "addseries":
			return a.cmdAddSeries(ctx, msg.Chat.ID, user, args)
		case "addepisode":
			return a.cmdAddEpisode(ctx, msg.Chat.ID, user, args)
		case "bulkepisodes":
			return a.cmdBulkEpisodes(ctx, msg.Chat.ID, user, args)
		case "alias":
			return a.cmdAlias(ctx, msg.Chat.ID, user, args)
		case "catalog", "catalogo", "catálogo":
			return a.cmdCatalog(ctx, msg.Chat.ID, user)
		case "search", "buscar":
			return a.cmdExternalSearch(ctx, msg.Chat.ID, user, args)
		case "importmovie":
			return a.cmdImportMovie(ctx, msg.Chat.ID, user, args)
		case "stats":
			return a.cmdStats(ctx, msg.Chat.ID, user)
		case "deletecontent":
			return a.cmdDeleteContent(ctx, msg.Chat.ID, user, args)
		default:
			return a.sendText(ctx, msg.Chat.ID, a.tr(user.LanguageCode, "unknown_command"), mainKeyboard(user.LanguageCode, a.isAdmin(user)))
		}
	}

	return a.handleSearchQuery(ctx, msg.Chat.ID, user, text)
}

func (a *App) ensureUser(ctx context.Context, from *tgbotapi.User, chatID int64, text string) (*User, error) {
	lang := detectLanguage(from.LanguageCode, text, a.cfg.DefaultLang)
	role := RoleUser
	if a.cfg.AdminIDs[int64(from.ID)] {
		role = RoleAdmin
	}

	anyAdmin, err := a.store.HasAnyAdmin(ctx)
	if err != nil {
		return nil, err
	}
	if !anyAdmin && len(a.cfg.AdminIDs) == 0 {
		role = RoleAdmin
	}

	u := &User{
		ID:           int64(from.ID),
		ChatID:       chatID,
		Username:     from.UserName,
		FirstName:    from.FirstName,
		LastName:     from.LastName,
		LanguageCode: lang,
		Role:         role,
	}
	stored, err := a.store.UpsertUser(ctx, u)
	if err != nil {
		return nil, err
	}
	if role == RoleAdmin && stored.Role != RoleAdmin {
		if err := a.store.SetUserRole(ctx, stored.ID, RoleAdmin); err != nil {
			return nil, err
		}
		stored.Role = RoleAdmin
	}
	if stored.LanguageCode == "" {
		stored.LanguageCode = lang
	}
	return stored, nil
}

func (a *App) isAdmin(u *User) bool {
	if u == nil {
		return false
	}
	return u.Role == RoleAdmin || a.cfg.AdminIDs[u.ID]
}

func (a *App) cmdStart(ctx context.Context, chatID int64, u *User) error {
	name := strings.TrimSpace(u.FirstName)
	if name == "" {
		name = "cinéfilo"
	}
	text := fmt.Sprintf(a.tr(u.LanguageCode, "welcome"), name)
	if a.isAdmin(u) {
		text += "\n\n" + a.tr(u.LanguageCode, "admin_short")
	}
	return a.sendText(ctx, chatID, text, mainKeyboard(u.LanguageCode, a.isAdmin(u)))
}

func (a *App) cmdHelp(ctx context.Context, chatID int64, u *User) error {
	text := a.tr(u.LanguageCode, "help")
	if a.isAdmin(u) {
		text += "\n\n" + a.tr(u.LanguageCode, "admin_help")
	}
	return a.sendText(ctx, chatID, text, mainKeyboard(u.LanguageCode, a.isAdmin(u)))
}

func (a *App) cmdLang(ctx context.Context, chatID int64, u *User, args string) error {
	if args == "" {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "choose_lang"), languageKeyboard())
	}
	lang := normalizeLang(args)
	if !isSupportedLang(lang) {
		return a.sendText(ctx, chatID, "Idiomas: es, en, pt, fr", languageKeyboard())
	}
	if err := a.store.SetUserLanguage(ctx, u.ID, lang, true); err != nil {
		return err
	}
	return a.sendText(ctx, chatID, a.tr(lang, "lang_set"), mainKeyboard(lang, a.isAdmin(u)))
}

func (a *App) cmdAdmin(ctx context.Context, chatID int64, u *User) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "admin_help"), nil)
}

func (a *App) cmdAddMovie(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	parts := splitPipes(args)
	if len(parts) < 4 {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "usage_addmovie"), nil)
	}
	title := parts[0]
	year, _ := strconv.Atoi(parts[1])
	quality := parts[2]
	sourceURL := parts[3]
	overview := ""
	if len(parts) >= 5 {
		overview = parts[4]
	}
	if err := validateSourceURL(sourceURL); err != nil {
		return a.sendText(ctx, chatID, fmt.Sprintf("URL inválida: %v", err), nil)
	}

	content, created, err := a.store.CreateOrGetContent(ctx, Content{
		Kind:      KindMovie,
		Title:     title,
		Year:      year,
		Overview:  overview,
		Language:  u.LanguageCode,
		CreatedBy: u.ID,
	})
	if err != nil {
		return err
	}
	mediaID, err := a.store.AddMediaItem(ctx, MediaItem{
		ContentID: content.ID,
		Season:    0,
		Episode:   0,
		Quality:   quality,
		AudioLang: u.LanguageCode,
		SourceURL: sourceURL,
	})
	if err != nil {
		return err
	}
	state := "actualizada"
	if created {
		state = "creada"
	}
	return a.sendText(ctx, chatID, fmt.Sprintf("✅ Película %s\n🎬 %s (%d)\n🆔 content=%d media=%d", state, content.Title, content.Year, content.ID, mediaID), nil)
}

func (a *App) cmdAddSeries(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	parts := splitPipes(args)
	if len(parts) < 2 {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "usage_addserie"), nil)
	}
	title := parts[0]
	year, _ := strconv.Atoi(parts[1])
	overview := ""
	if len(parts) >= 3 {
		overview = parts[2]
	}
	content, created, err := a.store.CreateOrGetContent(ctx, Content{
		Kind:      KindSeries,
		Title:     title,
		Year:      year,
		Overview:  overview,
		Language:  u.LanguageCode,
		CreatedBy: u.ID,
	})
	if err != nil {
		return err
	}
	state := "actualizada"
	if created {
		state = "creada"
	}
	return a.sendText(ctx, chatID, fmt.Sprintf("✅ Serie %s\n📺 %s (%d)\n🆔 content=%d", state, content.Title, content.Year, content.ID), nil)
}

func (a *App) cmdAddEpisode(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	parts := splitPipes(args)
	if len(parts) < 6 {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "usage_addepisode"), nil)
	}
	seriesTitle := parts[0]
	season, err := strconv.Atoi(parts[1])
	if err != nil || season < 1 {
		return a.sendText(ctx, chatID, "Temporada inválida", nil)
	}
	episode, err := strconv.Atoi(parts[2])
	if err != nil || episode < 1 {
		return a.sendText(ctx, chatID, "Episodio inválido", nil)
	}
	episodeTitle := parts[3]
	quality := parts[4]
	sourceURL := parts[5]
	if err := validateSourceURL(sourceURL); err != nil {
		return a.sendText(ctx, chatID, fmt.Sprintf("URL inválida: %v", err), nil)
	}

	content, _, err := a.store.CreateOrGetContent(ctx, Content{
		Kind:      KindSeries,
		Title:     seriesTitle,
		Language:  u.LanguageCode,
		CreatedBy: u.ID,
	})
	if err != nil {
		return err
	}
	mediaID, err := a.store.AddMediaItem(ctx, MediaItem{
		ContentID:    content.ID,
		Season:       season,
		Episode:      episode,
		EpisodeTitle: episodeTitle,
		Quality:      quality,
		AudioLang:    u.LanguageCode,
		SourceURL:    sourceURL,
	})
	if err != nil {
		return err
	}
	return a.sendText(ctx, chatID, fmt.Sprintf("✅ Episodio agregado\n📺 %s\n%s — %s\n🆔 media=%d", content.Title, episodeCode(season, episode), episodeTitle, mediaID), nil)
}

func (a *App) cmdBulkEpisodes(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	args = strings.TrimSpace(args)
	if args == "" || !strings.Contains(args, "\n") {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "usage_bulkepisodes"), nil)
	}
	lines := strings.Split(args, "\n")
	head := splitPipes(lines[0])
	if len(head) < 2 {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "usage_bulkepisodes"), nil)
	}
	seriesTitle := head[0]
	season, err := strconv.Atoi(head[1])
	if err != nil || season < 1 {
		return a.sendText(ctx, chatID, "Temporada inválida", nil)
	}
	content, _, err := a.store.CreateOrGetContent(ctx, Content{
		Kind:      KindSeries,
		Title:     seriesTitle,
		Language:  u.LanguageCode,
		CreatedBy: u.ID,
	})
	if err != nil {
		return err
	}

	added := 0
	var problems []string
	for i, raw := range lines[1:] {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		parts := splitPipes(line)
		if len(parts) < 4 {
			problems = append(problems, fmt.Sprintf("línea %d: formato inválido", i+2))
			continue
		}
		episode, err := strconv.Atoi(parts[0])
		if err != nil || episode < 1 {
			problems = append(problems, fmt.Sprintf("línea %d: episodio inválido", i+2))
			continue
		}
		episodeTitle := parts[1]
		quality := parts[2]
		sourceURL := parts[3]
		if err := validateSourceURL(sourceURL); err != nil {
			problems = append(problems, fmt.Sprintf("línea %d: URL inválida", i+2))
			continue
		}
		if _, err := a.store.AddMediaItem(ctx, MediaItem{
			ContentID:    content.ID,
			Season:       season,
			Episode:      episode,
			EpisodeTitle: episodeTitle,
			Quality:      quality,
			AudioLang:    u.LanguageCode,
			SourceURL:    sourceURL,
		}); err != nil {
			problems = append(problems, fmt.Sprintf("línea %d: %v", i+2, err))
			continue
		}
		added++
	}

	resp := fmt.Sprintf("✅ Bulk terminado\n📺 %s T%d\n➕ Agregados: %d", content.Title, season, added)
	if len(problems) > 0 {
		resp += "\n\n⚠️ Problemas:\n" + strings.Join(problems, "\n")
	}
	return a.sendText(ctx, chatID, resp, nil)
}

func (a *App) cmdAlias(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	parts := splitPipes(args)
	if len(parts) < 2 {
		return a.sendText(ctx, chatID, "Uso: /alias <content_id> | alias 1, alias 2", nil)
	}
	contentID, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || contentID <= 0 {
		return a.sendText(ctx, chatID, "content_id inválido", nil)
	}
	aliases := strings.Split(parts[1], ",")
	added := 0
	for _, alias := range aliases {
		alias = strings.TrimSpace(alias)
		if alias == "" {
			continue
		}
		if err := a.store.AddAlias(ctx, contentID, alias); err != nil {
			return err
		}
		added++
	}
	return a.sendText(ctx, chatID, fmt.Sprintf("✅ Alias agregados: %d", added), nil)
}

func (a *App) cmdCatalog(ctx context.Context, chatID int64, u *User) error {
	items, err := a.store.RecentContents(ctx, 15)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		return a.sendText(ctx, chatID, "Catálogo vacío. Un admin puede cargar contenido con /addmovie y /addepisode.", nil)
	}
	var sb strings.Builder
	sb.WriteString("🎞 Catálogo reciente\n\n")
	for _, c := range items {
		sb.WriteString(kindEmoji(c.Kind))
		sb.WriteString(" ")
		sb.WriteString(c.Title)
		if c.Year > 0 {
			sb.WriteString(fmt.Sprintf(" (%d)", c.Year))
		}
		sb.WriteString(fmt.Sprintf(" — ID %d\n", c.ID))
	}
	return a.sendText(ctx, chatID, sb.String(), nil)
}

func (a *App) cmdExternalSearch(ctx context.Context, chatID int64, u *User, args string) error {
	query := strings.TrimSpace(args)
	if query == "" {
		return a.sendText(ctx, chatID, "Uso: /search <título>\n\nBusca sólo en proveedores legales configurados. No se integran índices públicos asociados a piratería.", nil)
	}
	if !a.cfg.SearchEnabled {
		return a.sendText(ctx, chatID, "La búsqueda externa está desactivada. Activa SEARCH_ENABLED=true.", nil)
	}
	if err := a.sendTyping(ctx, chatID); err != nil {
		a.log.Debug("typing action failed", "error", err)
	}
	ids, err := a.searchAndStoreExternal(ctx, query, u.ID, a.cfg.SearchMaxResults)
	if err != nil {
		return a.sendText(ctx, chatID, fmt.Sprintf("⚠️ Error buscando fuentes externas legales: %v", err), nil)
	}
	if len(ids) == 0 {
		return a.sendText(ctx, chatID, fmt.Sprintf("🔎 No encontré resultados legales externos para “%s”.", query), nil)
	}
	return a.sendExternalSearchResults(ctx, chatID, u, query, ids, "")
}

func (a *App) cmdImportMovie(ctx context.Context, chatID int64, u *User, args string) error {
	id, err := strconv.ParseInt(strings.TrimSpace(args), 10, 64)
	if err != nil || id <= 0 {
		return a.sendText(ctx, chatID, "Uso: /importmovie <candidate_id>", nil)
	}
	return a.deliverExternalCandidate(ctx, chatID, u, id)
}

func (a *App) sendExternalSearchResults(ctx context.Context, chatID int64, u *User, query string, ids []int64, prefix string) error {
	candidates, err := a.store.GetExternalCandidates(ctx, ids)
	if err != nil {
		return err
	}
	if len(candidates) == 0 {
		return a.sendText(ctx, chatID, prefix, mainKeyboard(u.LanguageCode, a.isAdmin(u)))
	}
	var sb strings.Builder
	if strings.TrimSpace(prefix) != "" {
		sb.WriteString(prefix)
		sb.WriteString("\n\n")
	}
	sb.WriteString("🌱 Resultados externos legales/libres para “")
	sb.WriteString(query)
	sb.WriteString("”\n")
	sb.WriteString("Sólo usa contenido propio, público o con licencia abierta.\n\n")
	rows := make([][]tgbotapi.InlineKeyboardButton, 0, len(candidates)+1)
	for _, c := range candidates {
		label := fmt.Sprintf("▶️ %s", c.Title)
		if c.Year > 0 {
			label += fmt.Sprintf(" (%d)", c.Year)
		}
		if c.Provider != "" {
			label += " · " + c.Provider
		}
		if len([]rune(label)) > 60 {
			label = string([]rune(label)[:57]) + "..."
		}
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(label, fmt.Sprintf("x:%d", c.ID))))
		sb.WriteString(fmt.Sprintf("#%d · %s", c.ID, c.Title))
		if c.Year > 0 {
			sb.WriteString(fmt.Sprintf(" (%d)", c.Year))
		}
		if c.Provider != "" {
			sb.WriteString(" · " + c.Provider)
		}
		if c.SizeBytes > 0 {
			sb.WriteString(" · " + humanBytes(c.SizeBytes))
		}
		sb.WriteString("\n")
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(a.tr(u.LanguageCode, "search_again_button"), "search")))
	kb := tgbotapi.NewInlineKeyboardMarkup(rows...)
	return a.sendText(ctx, chatID, sb.String(), &kb)
}

func (a *App) deliverExternalCandidate(ctx context.Context, chatID int64, u *User, candidateID int64) error {
	candidate, err := a.store.GetExternalCandidate(ctx, candidateID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return a.sendText(ctx, chatID, "Ese resultado externo ya no existe o expiró. Vuelve a buscar.", nil)
		}
		return err
	}
	if err := validateSourceURL(candidate.SourceURL); err != nil {
		return a.sendText(ctx, chatID, fmt.Sprintf("Fuente externa inválida: %v", err), nil)
	}
	content, _, err := a.store.CreateOrGetContent(ctx, Content{
		Kind:      firstNonEmpty(candidate.Kind, KindMovie),
		Title:     candidate.Title,
		Year:      candidate.Year,
		Overview:  "Fuente externa legal/libre: " + candidate.Provider,
		Language:  u.LanguageCode,
		CreatedBy: u.ID,
	})
	if err != nil {
		return err
	}
	quality := firstNonEmpty(candidate.Quality, "torrent")
	mediaID, err := a.store.AddMediaItem(ctx, MediaItem{
		ContentID: content.ID,
		Season:    0,
		Episode:   0,
		Quality:   quality,
		AudioLang: u.LanguageCode,
		SourceURL: candidate.SourceURL,
		SizeBytes: candidate.SizeBytes,
	})
	if err != nil {
		return err
	}
	_ = a.store.LogRequest(ctx, u.ID, candidate.Title, content.ID, mediaID, "external_import", u.LanguageCode)
	return a.sendMediaItemLink(ctx, chatID, u, mediaID)
}

func (a *App) searchAndStoreExternal(ctx context.Context, query string, userID int64, limit int) ([]int64, error) {
	providers := a.searchProviders()
	if len(providers) == 0 {
		return nil, nil
	}
	if limit <= 0 {
		limit = 6
	}
	seen := map[string]bool{}
	ids := make([]int64, 0, limit)
	for _, provider := range providers {
		remaining := limit - len(ids)
		if remaining <= 0 {
			break
		}
		results, err := provider.Search(ctx, query, remaining)
		if err != nil {
			a.log.Warn("provider search failed", "provider", provider.Name(), "query", query, "error", err)
			continue
		}
		for _, r := range results {
			if len(ids) >= limit {
				break
			}
			if strings.TrimSpace(r.SourceURL) == "" {
				continue
			}
			if err := validateSourceURL(r.SourceURL); err != nil {
				a.log.Debug("provider returned invalid source", "provider", provider.Name(), "source", r.SourceURL, "error", err)
				continue
			}
			key := normalizeTitle(r.Title) + "|" + r.SourceURL
			if seen[key] {
				continue
			}
			seen[key] = true
			r.Provider = firstNonEmpty(r.Provider, provider.Name())
			if r.Kind == "" {
				r.Kind = KindMovie
			}
			id, err := a.store.SaveExternalCandidate(ctx, r, userID)
			if err != nil {
				return ids, err
			}
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (a *App) searchProviders() []TorrentSearchProvider {
	providers := []TorrentSearchProvider{
		NewWebTorrentSamplesProvider(),
		NewInternetArchiveProvider(),
	}
	if len(a.cfg.TorrentRSSURLs) > 0 {
		providers = append(providers, NewRSSProvider(a.cfg.TorrentRSSURLs, a.cfg.AllowedTorrentHosts))
	}
	return providers
}

func (a *App) cmdStats(ctx context.Context, chatID int64, u *User) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	stats, err := a.store.Stats(ctx)
	if err != nil {
		return err
	}
	text := fmt.Sprintf("📊 Qooq Cinema\n\n👥 Usuarios: %d\n🎬 Películas: %d\n📺 Series: %d\n🎞 Media items: %d\n🔗 Tokens activos: %d\n🔎 Búsquedas hoy: %d", stats.Users, stats.Movies, stats.Series, stats.MediaItems, stats.ActiveTokens, stats.RequestsToday)
	return a.sendText(ctx, chatID, text, nil)
}

func (a *App) cmdDeleteContent(ctx context.Context, chatID int64, u *User, args string) error {
	if !a.isAdmin(u) {
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "not_admin"), nil)
	}
	id, err := strconv.ParseInt(strings.TrimSpace(args), 10, 64)
	if err != nil || id <= 0 {
		return a.sendText(ctx, chatID, "Uso: /deletecontent <content_id>", nil)
	}
	if err := a.store.DeleteContent(ctx, id); err != nil {
		return err
	}
	return a.sendText(ctx, chatID, fmt.Sprintf("🗑️ Contenido %d eliminado", id), nil)
}

func (a *App) handleSearchQuery(ctx context.Context, chatID int64, u *User, query string) error {
	if err := a.sendTyping(ctx, chatID); err != nil {
		a.log.Debug("typing action failed", "error", err)
	}
	lang := detectLanguage(u.LanguageCode, query, a.cfg.DefaultLang)
	if !u.LanguageLocked && lang != u.LanguageCode {
		_ = a.store.SetUserLanguage(ctx, u.ID, lang, false)
		u.LanguageCode = lang
	}

	results, err := a.store.SearchContent(ctx, query, 8)
	if err != nil {
		return err
	}
	if len(results) == 0 {
		_ = a.store.LogRequest(ctx, u.ID, query, 0, 0, "not_found", u.LanguageCode)
		suggestions, _ := a.store.SuggestContent(ctx, query, 5)
		text := fmt.Sprintf(a.tr(u.LanguageCode, "no_results"), query)
		if len(suggestions) > 0 {
			text += "\n\n" + a.tr(u.LanguageCode, "suggestions") + "\n"
			for _, s := range suggestions {
				text += fmt.Sprintf("• %s %s", kindEmoji(s.Content.Kind), s.Content.Title)
				if s.Content.Year > 0 {
					text += fmt.Sprintf(" (%d)", s.Content.Year)
				}
				text += "\n"
			}
		}
		if a.cfg.SearchEnabled {
			extIDs, searchErr := a.searchAndStoreExternal(ctx, query, u.ID, a.cfg.SearchMaxResults)
			if searchErr != nil {
				a.log.Warn("external legal search failed", "query", query, "error", searchErr)
			} else if len(extIDs) > 0 {
				return a.sendExternalSearchResults(ctx, chatID, u, query, extIDs, text)
			}
		}
		return a.sendText(ctx, chatID, text, mainKeyboard(u.LanguageCode, a.isAdmin(u)))
	}

	if len(results) == 1 && (results[0].Exact || results[0].Score >= 780) {
		return a.deliverContent(ctx, chatID, u, results[0].Content.ID, query)
	}

	return a.sendSearchChoices(ctx, chatID, u, query, results)
}

func (a *App) sendSearchChoices(ctx context.Context, chatID int64, u *User, query string, results []SearchResult) error {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf(a.tr(u.LanguageCode, "choose_result"), query))
	sb.WriteString("\n")
	rows := make([][]tgbotapi.InlineKeyboardButton, 0, len(results)+1)
	for _, r := range results {
		label := fmt.Sprintf("%s %s", kindEmoji(r.Content.Kind), r.Content.Title)
		if r.Content.Year > 0 {
			label += fmt.Sprintf(" (%d)", r.Content.Year)
		}
		if len([]rune(label)) > 54 {
			label = string([]rune(label)[:51]) + "..."
		}
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(label, fmt.Sprintf("c:%d", r.Content.ID))))
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(a.tr(u.LanguageCode, "search_again_button"), "search")))
	kb := tgbotapi.NewInlineKeyboardMarkup(rows...)
	return a.sendText(ctx, chatID, sb.String(), &kb)
}

func (a *App) deliverContent(ctx context.Context, chatID int64, u *User, contentID int64, originalQuery string) error {
	content, err := a.store.GetContent(ctx, contentID)
	if err != nil {
		return err
	}
	if content.Kind == KindMovie {
		return a.sendMovieLink(ctx, chatID, u, content, originalQuery)
	}
	return a.sendSeriesLinks(ctx, chatID, u, content, originalQuery, 0)
}

func (a *App) sendMovieLink(ctx context.Context, chatID int64, u *User, content Content, originalQuery string) error {
	items, err := a.store.GetMovieMedia(ctx, content.ID)
	if err != nil {
		return err
	}
	if len(items) == 0 {
		_ = a.store.LogRequest(ctx, u.ID, originalQuery, content.ID, 0, "unavailable", u.LanguageCode)
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "unavailable"), nil)
	}
	sort.SliceStable(items, func(i, j int) bool { return qualityRank(items[i].Quality) > qualityRank(items[j].Quality) })
	best := items[0]
	link, exp, err := a.createWorkerLink(ctx, best.ID, u.ID)
	if err != nil {
		return err
	}
	_ = a.store.LogRequest(ctx, u.ID, originalQuery, content.ID, best.ID, "ok", u.LanguageCode)

	text := formatMovieCard(u.LanguageCode, content, best, link, exp)
	rows := [][]tgbotapi.InlineKeyboardButton{
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonURL(a.tr(u.LanguageCode, "open_link_button"), link)),
	}
	if len(items) > 1 {
		var qrow []tgbotapi.InlineKeyboardButton
		for _, it := range items {
			label := strings.TrimSpace(it.Quality)
			if label == "" {
				label = fmt.Sprintf("media %d", it.ID)
			}
			qrow = append(qrow, tgbotapi.NewInlineKeyboardButtonData(label, fmt.Sprintf("m:%d", it.ID)))
			if len(qrow) == 3 {
				rows = append(rows, qrow)
				qrow = nil
			}
		}
		if len(qrow) > 0 {
			rows = append(rows, qrow)
		}
	}
	rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(a.tr(u.LanguageCode, "search_again_button"), "search")))
	kb := tgbotapi.NewInlineKeyboardMarkup(rows...)
	return a.sendText(ctx, chatID, text, &kb)
}

func (a *App) sendMediaItemLink(ctx context.Context, chatID int64, u *User, mediaID int64) error {
	content, media, err := a.store.GetMediaWithContent(ctx, mediaID)
	if err != nil {
		return err
	}
	link, exp, err := a.createWorkerLink(ctx, media.ID, u.ID)
	if err != nil {
		return err
	}
	_ = a.store.LogRequest(ctx, u.ID, content.Title, content.ID, media.ID, "ok", u.LanguageCode)

	var text string
	if content.Kind == KindMovie {
		text = formatMovieCard(u.LanguageCode, content, media, link, exp)
	} else {
		text = fmt.Sprintf("📺 %s", content.Title)
		if content.Year > 0 {
			text += fmt.Sprintf(" (%d)", content.Year)
		}
		text += fmt.Sprintf("\n%s — %s", episodeCode(media.Season, media.Episode), nonEmpty(media.EpisodeTitle, "Episodio"))
		if media.Quality != "" {
			text += "\n🏷 " + media.Quality
		}
		text += fmt.Sprintf("\n\n🔗 %s\n⏳ %s", link, exp.Local().Format("2006-01-02 15:04"))
	}
	kb := tgbotapi.NewInlineKeyboardMarkup(tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonURL(a.tr(u.LanguageCode, "open_link_button"), link)))
	return a.sendText(ctx, chatID, text, &kb)
}

func (a *App) sendSeriesLinks(ctx context.Context, chatID int64, u *User, content Content, originalQuery string, seasonFilter int) error {
	var items []MediaItem
	var err error
	if seasonFilter > 0 {
		items, err = a.store.GetSeasonEpisodes(ctx, content.ID, seasonFilter)
	} else {
		items, err = a.store.GetEpisodes(ctx, content.ID)
	}
	if err != nil {
		return err
	}
	if len(items) == 0 {
		_ = a.store.LogRequest(ctx, u.ID, originalQuery, content.ID, 0, "unavailable", u.LanguageCode)
		return a.sendText(ctx, chatID, a.tr(u.LanguageCode, "unavailable"), nil)
	}
	best := bestEpisodeItems(items)
	if len(best) > a.cfg.MaxSeriesLinks && seasonFilter == 0 {
		seasons, err := a.store.GetSeasons(ctx, content.ID)
		if err != nil {
			return err
		}
		text := formatSeriesIntro(u.LanguageCode, content, len(best), seasons, a.cfg.MaxSeriesLinks)
		kb := seasonsKeyboard(u.LanguageCode, content.ID, seasons, true)
		return a.sendText(ctx, chatID, text, &kb)
	}

	links := make([]EpisodeLink, 0, len(best))
	for _, item := range best {
		link, exp, err := a.createWorkerLink(ctx, item.ID, u.ID)
		if err != nil {
			return err
		}
		links = append(links, EpisodeLink{Item: item, URL: link, ExpiresAt: exp})
	}
	if len(best) > 0 {
		_ = a.store.LogRequest(ctx, u.ID, originalQuery, content.ID, best[0].ID, "ok", u.LanguageCode)
	}

	texts := formatSeriesLinks(u.LanguageCode, content, links, seasonFilter)
	for i, text := range texts {
		var kb *tgbotapi.InlineKeyboardMarkup
		if i == len(texts)-1 {
			seasons, _ := a.store.GetSeasons(ctx, content.ID)
			if len(seasons) > 1 {
				k := seasonsKeyboard(u.LanguageCode, content.ID, seasons, seasonFilter > 0)
				kb = &k
			}
		}
		if err := a.sendText(ctx, chatID, text, kb); err != nil {
			return err
		}
		time.Sleep(250 * time.Millisecond)
	}
	return nil
}

type EpisodeLink struct {
	Item      MediaItem
	URL       string
	ExpiresAt time.Time
}

func (a *App) handleCallback(ctx context.Context, cb *tgbotapi.CallbackQuery) error {
	if cb.From == nil {
		return nil
	}
	chatID := int64(cb.From.ID)
	if cb.Message != nil && cb.Message.Chat != nil {
		chatID = cb.Message.Chat.ID
	}
	user, err := a.ensureUser(ctx, cb.From, chatID, "")
	if err != nil {
		return err
	}
	if user.IsBanned {
		return a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "banned"), true)
	}
	data := strings.TrimSpace(cb.Data)
	parts := strings.Split(data, ":")
	if len(parts) == 0 {
		return a.answerCallback(ctx, cb.ID, "OK", false)
	}

	switch parts[0] {
	case "c":
		if len(parts) != 2 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		contentID, _ := strconv.ParseInt(parts[1], 10, 64)
		_ = a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "loading"), false)
		return a.deliverContent(ctx, chatID, user, contentID, "callback")
	case "m":
		if len(parts) != 2 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		mediaID, _ := strconv.ParseInt(parts[1], 10, 64)
		_ = a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "loading"), false)
		return a.sendMediaItemLink(ctx, chatID, user, mediaID)
	case "x":
		if len(parts) != 2 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		candidateID, _ := strconv.ParseInt(parts[1], 10, 64)
		_ = a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "loading"), false)
		return a.deliverExternalCandidate(ctx, chatID, user, candidateID)
	case "season":
		if len(parts) != 3 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		contentID, _ := strconv.ParseInt(parts[1], 10, 64)
		season, _ := strconv.Atoi(parts[2])
		content, err := a.store.GetContent(ctx, contentID)
		if err != nil {
			return err
		}
		_ = a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "loading"), false)
		return a.sendSeriesLinks(ctx, chatID, user, content, content.Title, season)
	case "all":
		if len(parts) != 2 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		contentID, _ := strconv.ParseInt(parts[1], 10, 64)
		content, err := a.store.GetContent(ctx, contentID)
		if err != nil {
			return err
		}
		_ = a.answerCallback(ctx, cb.ID, a.tr(user.LanguageCode, "loading"), false)
		return a.sendSeriesLinks(ctx, chatID, user, content, content.Title, 0)
	case "lang":
		if len(parts) != 2 {
			return a.answerCallback(ctx, cb.ID, "Bad callback", true)
		}
		lang := normalizeLang(parts[1])
		if !isSupportedLang(lang) {
			return a.answerCallback(ctx, cb.ID, "Idioma no soportado", true)
		}
		if err := a.store.SetUserLanguage(ctx, user.ID, lang, true); err != nil {
			return err
		}
		_ = a.answerCallback(ctx, cb.ID, a.tr(lang, "lang_set"), false)
		return a.sendText(ctx, chatID, a.tr(lang, "lang_set"), mainKeyboard(lang, a.isAdmin(user)))
	case "choose_lang":
		_ = a.answerCallback(ctx, cb.ID, "OK", false)
		return a.sendText(ctx, chatID, a.tr(user.LanguageCode, "choose_lang"), languageKeyboard())
	case "help":
		_ = a.answerCallback(ctx, cb.ID, "OK", false)
		return a.cmdHelp(ctx, chatID, user)
	case "admin":
		_ = a.answerCallback(ctx, cb.ID, "OK", false)
		return a.cmdAdmin(ctx, chatID, user)
	case "search":
		_ = a.answerCallback(ctx, cb.ID, "OK", false)
		return a.sendText(ctx, chatID, a.tr(user.LanguageCode, "ask_search"), nil)
	default:
		return a.answerCallback(ctx, cb.ID, "OK", false)
	}
}

func (a *App) createWorkerLink(ctx context.Context, mediaID int64, userID int64) (string, time.Time, error) {
	raw, err := randomBase64(24)
	if err != nil {
		return "", time.Time{}, err
	}
	signed := signToken(a.cfg.HashSecret, raw)
	expires := time.Now().UTC().Add(a.cfg.LinkTTL)
	if err := a.store.CreateAccessToken(ctx, signed, mediaID, userID, expires); err != nil {
		return "", time.Time{}, err
	}
	return strings.TrimRight(a.cfg.WorkerBaseURL, "/") + "/w/" + url.PathEscape(signed), expires, nil
}

type ResolvedPlayback struct {
	StreamURL   string          `json:"stream_url"`
	DownloadURL string          `json:"download_url,omitempty"`
	SourceKind  string          `json:"source_kind"`
	IsVideo     bool            `json:"is_video"`
	Webtor      *ResolvedWebtor `json:"webtor,omitempty"`
}

type ResolvedWebtor struct {
	ResourceID   string `json:"resource_id"`
	ContentID    string `json:"content_id"`
	FileName     string `json:"file_name"`
	Path         string `json:"path"`
	Size         int64  `json:"size"`
	MediaFormat  string `json:"media_format"`
	Transcoded   bool   `json:"transcoded,omitempty"`
	Cached       bool   `json:"cached,omitempty"`
	DownloadOnly bool   `json:"download_only,omitempty"`
}

func (a *App) resolvePlaybackURL(ctx context.Context, media MediaItem) (ResolvedPlayback, error) {
	source := strings.TrimSpace(media.SourceURL)
	if source == "" {
		return ResolvedPlayback{}, errors.New("empty source_url")
	}
	if isMagnetURI(source) {
		return a.resolveWebtorStream(ctx, source)
	}
	if isTorrentFileURL(source) {
		return a.resolveWebtorTorrentURL(ctx, source)
	}
	return ResolvedPlayback{
		StreamURL:   source,
		DownloadURL: source,
		SourceKind:  "url",
		IsVideo:     isProbablyVideo(source),
	}, nil
}

type webtorResourceResponse struct {
	ID        string `json:"id"`
	Name      string `json:"name,omitempty"`
	MagnetURI string `json:"magnet_uri,omitempty"`
}

type webtorListItem struct {
	ID          string `json:"id"`
	Name        string `json:"name,omitempty"`
	PathStr     string `json:"path"`
	Type        string `json:"type"`
	Size        int64  `json:"size"`
	MediaFormat string `json:"media_format,omitempty"`
	MimeType     string `json:"mime_type,omitempty"`
	Ext         string `json:"ext,omitempty"`
}

type webtorListResponse struct {
	webtorListItem
	Items []webtorListItem `json:"items"`
	Count int              `json:"items_count"`
}

type webtorExportMeta struct {
	Transcode      bool `json:"transcode,omitempty"`
	Multibitrate   bool `json:"multibitrate,omitempty"`
	Cache          bool `json:"cache,omitempty"`
	TranscodeCache bool `json:"transcode_cache,omitempty"`
}

type webtorExportItem struct {
	URL  string           `json:"url,omitempty"`
	Meta *webtorExportMeta `json:"meta,omitempty"`
}

type webtorExportResponse struct {
	Source  webtorListItem              `json:"source"`
	Exports map[string]webtorExportItem `json:"exports"`
}

func (a *App) resolveWebtorStream(ctx context.Context, magnetURI string) (ResolvedPlayback, error) {
	return a.resolveWebtorResource(ctx, []byte(magnetURI))
}

func (a *App) resolveWebtorTorrentURL(ctx context.Context, torrentURL string) (ResolvedPlayback, error) {
	if !a.cfg.WebtorEnabled {
		return ResolvedPlayback{}, errors.New("WEBTOR_ENABLED=false; torrent streaming is disabled")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, torrentURL, nil)
	if err != nil {
		return ResolvedPlayback{}, err
	}
	req.Header.Set("User-Agent", "QooqCinemaBot/1.0 torrent-fetch")
	client := &http.Client{Timeout: a.cfg.WebtorTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return ResolvedPlayback{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		bb, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return ResolvedPlayback{}, fmt.Errorf("torrent file status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(bb)))
	}
	bb, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return ResolvedPlayback{}, err
	}
	if len(bb) == 0 {
		return ResolvedPlayback{}, errors.New("empty torrent file")
	}
	return a.resolveWebtorResource(ctx, bb)
}

func (a *App) resolveWebtorResource(ctx context.Context, resourceBody []byte) (ResolvedPlayback, error) {
	if !a.cfg.WebtorEnabled {
		return ResolvedPlayback{}, errors.New("WEBTOR_ENABLED=false; torrent streaming is disabled")
	}
	if a.cfg.WebtorAPIBaseURL == "" {
		return ResolvedPlayback{}, errors.New("WEBTOR_API_BASE_URL is empty")
	}
	resource, err := a.webtorCreateResourceBytes(ctx, resourceBody)
	if err != nil {
		return ResolvedPlayback{}, fmt.Errorf("webtor create resource: %w", err)
	}
	items, err := a.webtorListResource(ctx, resource.ID)
	if err != nil {
		return ResolvedPlayback{}, fmt.Errorf("webtor list resource %s: %w", resource.ID, err)
	}
	item, ok := pickWebtorPlayable(items)
	if !ok {
		return ResolvedPlayback{}, fmt.Errorf("webtor resource %s has no playable files", resource.ID)
	}
	exports, err := a.webtorExport(ctx, resource.ID, item.ID)
	if err != nil {
		return ResolvedPlayback{}, fmt.Errorf("webtor export %s/%s: %w", resource.ID, item.ID, err)
	}
	stream := strings.TrimSpace(exports.Exports["stream"].URL)
	download := strings.TrimSpace(exports.Exports["download"].URL)
	downloadOnly := false
	if stream == "" {
		stream = download
		downloadOnly = true
	}
	if stream == "" {
		return ResolvedPlayback{}, fmt.Errorf("webtor export returned no stream/download URL for %s", item.PathStr)
	}
	stream = rewriteURLBase(stream, a.cfg.WebtorRewriteExportBase)
	download = rewriteURLBase(download, a.cfg.WebtorRewriteExportBase)
	if download == "" {
		download = stream
	}
	meta := exports.Exports["stream"].Meta
	webtor := &ResolvedWebtor{ResourceID: resource.ID, ContentID: item.ID, FileName: nonEmpty(item.Name, item.PathStr), Path: item.PathStr, Size: item.Size, MediaFormat: item.MediaFormat, DownloadOnly: downloadOnly}
	if meta != nil {
		webtor.Transcoded = meta.Transcode
		webtor.Cached = meta.Cache || meta.TranscodeCache
	}
	return ResolvedPlayback{StreamURL: stream, DownloadURL: download, SourceKind: "torrent", IsVideo: item.MediaFormat == "video" || isVideoExt(item.Ext) || strings.Contains(strings.ToLower(item.MimeType), "video"), Webtor: webtor}, nil
}

func (a *App) webtorCreateResourceBytes(ctx context.Context, body []byte) (webtorResourceResponse, error) {
	var out webtorResourceResponse
	err := a.webtorJSON(ctx, http.MethodPost, "/resource/", body, &out)
	return out, err
}

func (a *App) webtorListResource(ctx context.Context, resourceID string) ([]webtorListItem, error) {
	var out webtorListResponse
	path := fmt.Sprintf("/resource/%s/list?output=list&sort=size&limit=1000", url.PathEscape(resourceID))
	if err := a.webtorJSON(ctx, http.MethodGet, path, nil, &out); err != nil {
		return nil, err
	}
	return out.Items, nil
}

func (a *App) webtorExport(ctx context.Context, resourceID string, contentID string) (webtorExportResponse, error) {
	var out webtorExportResponse
	path := fmt.Sprintf("/resource/%s/export/%s?types=stream,download", url.PathEscape(resourceID), url.PathEscape(contentID))
	err := a.webtorJSON(ctx, http.MethodGet, path, nil, &out)
	return out, err
}

func (a *App) webtorJSON(ctx context.Context, method string, path string, body []byte, out any) error {
	endpoint := strings.TrimRight(a.cfg.WebtorAPIBaseURL, "/") + "/" + strings.TrimLeft(path, "/")
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return err
	}
	if body != nil {
		if bytes.HasPrefix(bytes.ToLower(bytes.TrimSpace(body)), []byte("magnet:?")) {
			req.Header.Set("Content-Type", "text/plain; charset=utf-8")
		} else {
			req.Header.Set("Content-Type", "application/x-bittorrent")
		}
	}
	req.Header.Set("Accept", "application/json")
	if a.cfg.WebtorAPIKey != "" {
		req.Header.Set("X-Api-Key", a.cfg.WebtorAPIKey)
	}
	if a.cfg.WebtorAPIToken != "" {
		req.Header.Set("X-Token", a.cfg.WebtorAPIToken)
	}

	client := &http.Client{Timeout: a.cfg.WebtorTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		bb, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("webtor status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(bb)))
	}
	if out == nil {
		return nil
	}
	dec := json.NewDecoder(resp.Body)
	if err := dec.Decode(out); err != nil {
		return fmt.Errorf("decode webtor json: %w", err)
	}
	return nil
}

func pickWebtorPlayable(items []webtorListItem) (webtorListItem, bool) {
	var best webtorListItem
	bestPriority := -1
	found := false
	for _, item := range items {
		if item.Type != "file" {
			continue
		}
		priority := webtorMediaPriority(item)
		if !found || priority > bestPriority || (priority == bestPriority && item.Size > best.Size) {
			best = item
			bestPriority = priority
			found = true
		}
	}
	return best, found
}

func webtorMediaPriority(item webtorListItem) int {
	mf := strings.ToLower(item.MediaFormat)
	ext := strings.ToLower(strings.TrimPrefix(item.Ext, "."))
	mime := strings.ToLower(item.MimeType)
	switch {
	case mf == "video" || strings.HasPrefix(mime, "video/") || isVideoExt(ext):
		return 3
	case mf == "audio" || strings.HasPrefix(mime, "audio/") || isAudioExt(ext):
		return 2
	case ext == "srt" || ext == "vtt":
		return 1
	default:
		return 0
	}
}

func rewriteURLBase(raw string, base string) string {
	raw = strings.TrimSpace(raw)
	base = strings.TrimSpace(base)
	if raw == "" || base == "" {
		return raw
	}
	ru, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	bu, err := url.Parse(base)
	if err != nil || bu.Scheme == "" || bu.Host == "" {
		return raw
	}
	ru.Scheme = bu.Scheme
	ru.Host = bu.Host
	prefix := strings.TrimRight(bu.Path, "/")
	if prefix != "" && !strings.HasPrefix(ru.Path, prefix+"/") {
		ru.Path = prefix + ru.Path
	}
	return ru.String()
}

func (a *App) sendText(ctx context.Context, chatID int64, text string, markup *tgbotapi.InlineKeyboardMarkup) error {
	chunks := splitLong(text, MaxTelegramText)
	for i, chunk := range chunks {
		msg := tgbotapi.NewMessage(chatID, chunk)
		msg.DisableWebPagePreview = true
		if markup != nil && i == len(chunks)-1 {
			msg.ReplyMarkup = *markup
		}
		if err := a.sendWithRetry(ctx, msg); err != nil {
			return err
		}
	}
	return nil
}

func (a *App) sendTyping(ctx context.Context, chatID int64) error {
	_, err := a.bot.Request(tgbotapi.NewChatAction(chatID, tgbotapi.ChatTyping))
	return err
}

func (a *App) answerCallback(ctx context.Context, callbackID string, text string, alert bool) error {
	cfg := tgbotapi.NewCallback(callbackID, text)
	cfg.ShowAlert = alert
	return a.requestWithRetry(ctx, cfg)
}

func (a *App) sendWithRetry(ctx context.Context, c tgbotapi.Chattable) error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		_, err := a.bot.Send(c)
		if err == nil {
			return nil
		}
		lastErr = err
		delay := telegramRetryDelay(err, attempt)
		a.log.Warn("telegram send failed", "attempt", attempt+1, "retry_in", delay.String(), "error", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return lastErr
}

func (a *App) requestWithRetry(ctx context.Context, c tgbotapi.Chattable) error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		_, err := a.bot.Request(c)
		if err == nil {
			return nil
		}
		lastErr = err
		delay := telegramRetryDelay(err, attempt)
		a.log.Warn("telegram request failed", "attempt", attempt+1, "retry_in", delay.String(), "error", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return lastErr
}

func telegramRetryDelay(err error, attempt int) time.Duration {
	var tgErr tgbotapi.Error
	if errors.As(err, &tgErr) && tgErr.RetryAfter > 0 {
		return time.Duration(tgErr.RetryAfter+1) * time.Second
	}
	base := time.Duration(300*(1<<attempt)) * time.Millisecond
	if base > 5*time.Second {
		return 5 * time.Second
	}
	return base
}

// ───────────────────────────────────────────────────────────────────────────────
// HTTP Worker endpoint
// ───────────────────────────────────────────────────────────────────────────────

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/w/", a.handleWorkerLink)
	mux.HandleFunc("/", a.handleHome)
	return requestLogger(a.log, mux)
}

func (a *App) handleHome(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(`<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Qooq Cinema</title><style>body{margin:0;font-family:system-ui;background:#070914;color:#f8fafc;display:grid;place-items:center;min-height:100vh}main{max-width:720px;padding:40px;border:1px solid #24304a;border-radius:28px;background:linear-gradient(160deg,#111827,#0b1020);box-shadow:0 30px 80px #0008}h1{font-size:42px;margin:0 0 12px;background:linear-gradient(90deg,#7c3aed,#06b6d4);-webkit-background-clip:text;color:transparent}p{color:#cbd5e1;line-height:1.6}code{background:#111827;border:1px solid #334155;padding:3px 7px;border-radius:8px}</style></head><body><main><h1>🎬 Qooq Cinema</h1><p>Servidor activo. Los enlaces del bot viven en <code>/w/{token}</code>.</p><p>Si usas Cloudflare Worker, configura el Worker para reenviar esas rutas a este servidor Go.</p></main></body></html>`))
}

func (a *App) handleWorkerLink(w http.ResponseWriter, r *http.Request) {
	timeout := 20 * time.Second
	if a.cfg.WebtorEnabled && a.cfg.WebtorTimeout > timeout {
		timeout = a.cfg.WebtorTimeout
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	token := strings.TrimPrefix(r.URL.Path, "/w/")
	token, _ = url.PathUnescape(token)
	token = strings.TrimSpace(token)
	if token == "" || !verifySignedToken(a.cfg.HashSecret, token) {
		http.Error(w, "invalid link", http.StatusBadRequest)
		return
	}
	info, err := a.store.GetTokenInfo(ctx, token)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			http.Error(w, "link not found", http.StatusNotFound)
			return
		}
		a.log.Error("token lookup failed", "error", err)
		http.Error(w, "server error", http.StatusInternalServerError)
		return
	}
	exp, err := time.Parse(time.RFC3339, info.ExpiresAt)
	if err != nil || time.Now().UTC().After(exp) {
		http.Error(w, "link expired", http.StatusGone)
		return
	}
	if err := a.store.TouchToken(ctx, token); err != nil {
		a.log.Warn("touch token failed", "error", err)
	}

	playback, err := a.resolvePlaybackURL(ctx, info.Media)
	if err != nil {
		a.log.Error("resolve playback failed", "media_id", info.Media.ID, "error", err)
		http.Error(w, "stream source unavailable", http.StatusBadGateway)
		return
	}

	if r.URL.Query().Get("raw") == "1" || a.cfg.LinkMode == "json" {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"title":        info.Content.Title,
			"kind":         info.Content.Kind,
			"year":         info.Content.Year,
			"season":       info.Media.Season,
			"episode":      info.Media.Episode,
			"episodeTitle": info.Media.EpisodeTitle,
			"quality":      info.Media.Quality,
			"source_kind":  playback.SourceKind,
			"source_url":   playback.StreamURL,
			"download_url": playback.DownloadURL,
			"webtor":       playback.Webtor,
			"expires_at":   info.ExpiresAt,
		})
		return
	}

	if a.cfg.LinkMode == "redirect" {
		http.Redirect(w, r, playback.StreamURL, http.StatusFound)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	data := LandingData{
		Title:        info.Content.Title,
		Kind:         info.Content.Kind,
		Year:         info.Content.Year,
		Season:       info.Media.Season,
		Episode:      info.Media.Episode,
		EpisodeTitle: nonEmpty(info.Media.EpisodeTitle, info.Content.Title),
		Quality:      info.Media.Quality,
		SourceKind:   playback.SourceKind,
		SourceURL:    playback.StreamURL,
		DownloadURL:  nonEmpty(playback.DownloadURL, playback.StreamURL),
		IsVideo:      playback.IsVideo,
		ExpiresAt:    exp.Local().Format("2006-01-02 15:04"),
	}
	if err := landingTemplate.Execute(w, data); err != nil {
		a.log.Error("render landing failed", "error", err)
	}
}

type LandingData struct {
	Title        string
	Kind         string
	Year         int
	Season       int
	Episode      int
	EpisodeTitle string
	Quality      string
	SourceKind   string
	SourceURL    string
	DownloadURL  string
	IsVideo      bool
	ExpiresAt    string
}

var landingTemplate = template.Must(template.New("landing").Parse(`<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{.Title}} — Qooq Cinema</title>
<style>
:root{color-scheme:dark;--bg:#050816;--card:#0f172a;--muted:#94a3b8;--txt:#f8fafc;--pri:#8b5cf6;--sec:#06b6d4;--line:#23314d}
*{box-sizing:border-box}body{margin:0;min-height:100vh;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif;background:radial-gradient(circle at 20% 10%,#312e8180,transparent 35%),radial-gradient(circle at 90% 80%,#0e749080,transparent 30%),var(--bg);color:var(--txt);display:flex;align-items:center;justify-content:center;padding:24px}.card{width:min(980px,100%);border:1px solid var(--line);border-radius:30px;background:linear-gradient(160deg,#111827ee,#0b1020ee);box-shadow:0 30px 100px #000a;overflow:hidden}.hero{padding:34px}.badge{display:inline-flex;gap:8px;align-items:center;border:1px solid #334155;background:#0b1222;border-radius:999px;color:#cbd5e1;padding:8px 13px;font-size:14px}.title{font-size:clamp(30px,5vw,58px);line-height:1.05;margin:20px 0 10px;background:linear-gradient(90deg,#ddd6fe,#67e8f9);-webkit-background-clip:text;color:transparent}.meta{color:var(--muted);font-size:16px;line-height:1.7}.player{padding:0 22px 22px}.video{width:100%;max-height:62vh;background:#000;border:1px solid #1e293b;border-radius:22px}.actions{display:flex;flex-wrap:wrap;gap:12px;margin-top:22px}.btn{appearance:none;text-decoration:none;border:0;border-radius:16px;padding:14px 18px;font-weight:800;color:white;background:linear-gradient(90deg,var(--pri),var(--sec));box-shadow:0 15px 40px #0891b244}.btn.secondary{background:#111827;border:1px solid #334155;box-shadow:none;color:#e2e8f0}.foot{color:#64748b;font-size:13px;padding:0 34px 30px}.glow{position:fixed;inset:auto 0 0 0;height:2px;background:linear-gradient(90deg,var(--pri),var(--sec))}
</style>
</head>
<body>
<div class="card">
  <section class="hero">
    <div class="badge">🎬 Qooq Cinema · {{.Kind}}{{if .Quality}} · {{.Quality}}{{end}}{{if eq .SourceKind "torrent"}} · Webtor torrent{{end}}</div>
    <h1 class="title">{{.Title}}{{if .Year}} ({{.Year}}){{end}}</h1>
    <div class="meta">{{if gt .Season 0}}📺 S{{printf "%02d" .Season}}E{{printf "%02d" .Episode}} — {{.EpisodeTitle}}<br>{{end}}⏳ Enlace válido hasta {{.ExpiresAt}}</div>
    <div class="actions">
      <a class="btn" href="{{.SourceURL}}">▶ Abrir reproducción</a>
      <a class="btn secondary" href="{{.DownloadURL}}" download>⬇ Descargar / abrir externo</a>
    </div>
  </section>
  {{if .IsVideo}}<section class="player"><video class="video" src="{{.SourceURL}}" controls playsinline preload="metadata"></video></section>{{end}}
  <div class="foot">Si el reproductor no inicia, usa “Abrir reproducción”.</div>
</div><div class="glow"></div>
</body>
</html>`))

func requestLogger(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Debug("http request", "method", r.Method, "path", r.URL.Path, "remote", r.RemoteAddr, "duration", time.Since(start))
	})
}

// ───────────────────────────────────────────────────────────────────────────────
// Database
// ───────────────────────────────────────────────────────────────────────────────

func (s *Store) Migrate(ctx context.Context) error {
	stmts := []string{
		`PRAGMA journal_mode=WAL;`,
		`PRAGMA foreign_keys=ON;`,
		`PRAGMA busy_timeout=5000;`,
		`CREATE TABLE IF NOT EXISTS users (
			id INTEGER PRIMARY KEY,
			chat_id INTEGER NOT NULL,
			username TEXT NOT NULL DEFAULT '',
			first_name TEXT NOT NULL DEFAULT '',
			last_name TEXT NOT NULL DEFAULT '',
			language_code TEXT NOT NULL DEFAULT 'es',
			language_locked INTEGER NOT NULL DEFAULT 0,
			role TEXT NOT NULL DEFAULT 'user',
			is_banned INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			last_seen_at TEXT NOT NULL
		);`,
		`CREATE TABLE IF NOT EXISTS contents (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			kind TEXT NOT NULL CHECK(kind IN ('movie','series')),
			title TEXT NOT NULL,
			normalized_title TEXT NOT NULL,
			original_title TEXT NOT NULL DEFAULT '',
			year INTEGER NOT NULL DEFAULT 0,
			overview TEXT NOT NULL DEFAULT '',
			poster_url TEXT NOT NULL DEFAULT '',
			language TEXT NOT NULL DEFAULT '',
			created_by INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL,
			updated_at TEXT NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_contents_kind_norm ON contents(kind, normalized_title);`,
		`CREATE INDEX IF NOT EXISTS idx_contents_year ON contents(year);`,
		`CREATE TABLE IF NOT EXISTS content_aliases (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
			alias TEXT NOT NULL,
			normalized_alias TEXT NOT NULL,
			created_at TEXT NOT NULL,
			UNIQUE(content_id, normalized_alias)
		);`,
		`CREATE INDEX IF NOT EXISTS idx_aliases_norm ON content_aliases(normalized_alias);`,
		`CREATE TABLE IF NOT EXISTS media_items (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			content_id INTEGER NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
			season INTEGER NOT NULL DEFAULT 0,
			episode INTEGER NOT NULL DEFAULT 0,
			episode_title TEXT NOT NULL DEFAULT '',
			quality TEXT NOT NULL DEFAULT '',
			audio_lang TEXT NOT NULL DEFAULT '',
			subtitle_lang TEXT NOT NULL DEFAULT '',
			source_url TEXT NOT NULL,
			size_bytes INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_media_content_episode ON media_items(content_id, season, episode);`,
		`CREATE TABLE IF NOT EXISTS access_tokens (
			token TEXT PRIMARY KEY,
			media_item_id INTEGER NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
			user_id INTEGER NOT NULL,
			expires_at TEXT NOT NULL,
			created_at TEXT NOT NULL,
			used_at TEXT NOT NULL DEFAULT '',
			hits INTEGER NOT NULL DEFAULT 0
		);`,
		`CREATE INDEX IF NOT EXISTS idx_tokens_media ON access_tokens(media_item_id);`,
		`CREATE INDEX IF NOT EXISTS idx_tokens_exp ON access_tokens(expires_at);`,
		`CREATE TABLE IF NOT EXISTS requests (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id INTEGER NOT NULL,
			query TEXT NOT NULL,
			normalized_query TEXT NOT NULL,
			matched_content_id INTEGER NOT NULL DEFAULT 0,
			matched_media_id INTEGER NOT NULL DEFAULT 0,
			status TEXT NOT NULL,
			language TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_requests_user_created ON requests(user_id, created_at);`,
		`CREATE TABLE IF NOT EXISTS external_candidates (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			provider TEXT NOT NULL DEFAULT '',
			title TEXT NOT NULL,
			kind TEXT NOT NULL DEFAULT 'movie',
			year INTEGER NOT NULL DEFAULT 0,
			quality TEXT NOT NULL DEFAULT '',
			source_url TEXT NOT NULL,
			info_url TEXT NOT NULL DEFAULT '',
			size_bytes INTEGER NOT NULL DEFAULT 0,
			seeders INTEGER NOT NULL DEFAULT 0,
			created_by INTEGER NOT NULL DEFAULT 0,
			created_at TEXT NOT NULL
		);`,
		`CREATE INDEX IF NOT EXISTS idx_external_candidates_created ON external_candidates(created_at);`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migration statement failed: %w\n%s", err, stmt)
		}
	}
	return nil
}

func (s *Store) UpsertUser(ctx context.Context, u *User) (*User, error) {
	now := nowUTC()
	existing, err := s.GetUser(ctx, u.ID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if errors.Is(err, sql.ErrNoRows) {
		if u.LanguageCode == "" {
			u.LanguageCode = "es"
		}
		if u.Role == "" {
			u.Role = RoleUser
		}
		_, err := s.db.ExecContext(ctx, `INSERT INTO users(id, chat_id, username, first_name, last_name, language_code, language_locked, role, is_banned, created_at, updated_at, last_seen_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
			u.ID, u.ChatID, u.Username, u.FirstName, u.LastName, u.LanguageCode, boolToInt(u.LanguageLocked), u.Role, boolToInt(u.IsBanned), now, now, now)
		if err != nil {
			return nil, err
		}
		return s.GetUser(ctx, u.ID)
	}

	lang := existing.LanguageCode
	if !existing.LanguageLocked && u.LanguageCode != "" {
		lang = u.LanguageCode
	}
	role := existing.Role
	if u.Role == RoleAdmin {
		role = RoleAdmin
	}
	_, err = s.db.ExecContext(ctx, `UPDATE users SET chat_id=?, username=?, first_name=?, last_name=?, language_code=?, role=?, updated_at=?, last_seen_at=? WHERE id=?`,
		u.ChatID, u.Username, u.FirstName, u.LastName, lang, role, now, now, u.ID)
	if err != nil {
		return nil, err
	}
	return s.GetUser(ctx, u.ID)
}

func (s *Store) GetUser(ctx context.Context, id int64) (*User, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, chat_id, username, first_name, last_name, language_code, language_locked, role, is_banned, created_at, updated_at, last_seen_at FROM users WHERE id=?`, id)
	var u User
	var locked, banned int
	if err := row.Scan(&u.ID, &u.ChatID, &u.Username, &u.FirstName, &u.LastName, &u.LanguageCode, &locked, &u.Role, &banned, &u.CreatedAt, &u.UpdatedAt, &u.LastSeenAt); err != nil {
		return nil, err
	}
	u.LanguageLocked = locked == 1
	u.IsBanned = banned == 1
	return &u, nil
}

func (s *Store) SetUserLanguage(ctx context.Context, id int64, lang string, locked bool) error {
	_, err := s.db.ExecContext(ctx, `UPDATE users SET language_code=?, language_locked=?, updated_at=? WHERE id=?`, normalizeLang(lang), boolToInt(locked), nowUTC(), id)
	return err
}

func (s *Store) SetUserRole(ctx context.Context, id int64, role string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE users SET role=?, updated_at=? WHERE id=?`, role, nowUTC(), id)
	return err
}

func (s *Store) HasAnyAdmin(ctx context.Context) (bool, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(1) FROM users WHERE role='admin'`).Scan(&count); err != nil {
		return false, err
	}
	return count > 0, nil
}

func (s *Store) CreateOrGetContent(ctx context.Context, c Content) (Content, bool, error) {
	c.Title = strings.TrimSpace(c.Title)
	if c.Title == "" {
		return Content{}, false, errors.New("title is required")
	}
	if c.Kind != KindMovie && c.Kind != KindSeries {
		return Content{}, false, errors.New("invalid content kind")
	}
	c.Normalized = normalizeTitle(c.Title)
	now := nowUTC()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Content{}, false, err
	}
	defer func() { _ = tx.Rollback() }()

	var id int64
	query := `SELECT id FROM contents WHERE kind=? AND normalized_title=? AND (?=0 OR year=? OR year=0) ORDER BY CASE WHEN year=? THEN 0 ELSE 1 END, id LIMIT 1`
	err = tx.QueryRowContext(ctx, query, c.Kind, c.Normalized, c.Year, c.Year, c.Year).Scan(&id)
	if err == nil {
		if c.Overview != "" {
			_, _ = tx.ExecContext(ctx, `UPDATE contents SET overview=CASE WHEN overview='' THEN ? ELSE overview END, updated_at=? WHERE id=?`, c.Overview, now, id)
		}
		if c.Year > 0 {
			_, _ = tx.ExecContext(ctx, `UPDATE contents SET year=CASE WHEN year=0 THEN ? ELSE year END, updated_at=? WHERE id=?`, c.Year, now, id)
		}
		_, _ = tx.ExecContext(ctx, `INSERT OR IGNORE INTO content_aliases(content_id, alias, normalized_alias, created_at) VALUES(?,?,?,?)`, id, c.Title, c.Normalized, now)
		if err := tx.Commit(); err != nil {
			return Content{}, false, err
		}
		content, err := s.GetContent(ctx, id)
		return content, false, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return Content{}, false, err
	}

	res, err := tx.ExecContext(ctx, `INSERT INTO contents(kind, title, normalized_title, original_title, year, overview, poster_url, language, created_by, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
		c.Kind, c.Title, c.Normalized, c.OriginalTitle, c.Year, c.Overview, c.PosterURL, c.Language, c.CreatedBy, now, now)
	if err != nil {
		return Content{}, false, err
	}
	id, err = res.LastInsertId()
	if err != nil {
		return Content{}, false, err
	}
	_, err = tx.ExecContext(ctx, `INSERT OR IGNORE INTO content_aliases(content_id, alias, normalized_alias, created_at) VALUES(?,?,?,?)`, id, c.Title, c.Normalized, now)
	if err != nil {
		return Content{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return Content{}, false, err
	}
	content, err := s.GetContent(ctx, id)
	return content, true, err
}

func (s *Store) AddAlias(ctx context.Context, contentID int64, alias string) error {
	alias = strings.TrimSpace(alias)
	if alias == "" {
		return errors.New("alias is empty")
	}
	_, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO content_aliases(content_id, alias, normalized_alias, created_at) VALUES(?,?,?,?)`, contentID, alias, normalizeTitle(alias), nowUTC())
	return err
}

func (s *Store) AddMediaItem(ctx context.Context, item MediaItem) (int64, error) {
	if item.ContentID <= 0 {
		return 0, errors.New("content_id is required")
	}
	if strings.TrimSpace(item.SourceURL) == "" {
		return 0, errors.New("source_url is required")
	}
	now := nowUTC()
	var existingID int64
	err := s.db.QueryRowContext(ctx, `SELECT id FROM media_items WHERE content_id=? AND season=? AND episode=? AND quality=? AND source_url=? LIMIT 1`, item.ContentID, item.Season, item.Episode, item.Quality, item.SourceURL).Scan(&existingID)
	if err == nil {
		_, err = s.db.ExecContext(ctx, `UPDATE media_items SET episode_title=?, audio_lang=?, subtitle_lang=?, size_bytes=? WHERE id=?`, item.EpisodeTitle, item.AudioLang, item.SubtitleLang, item.SizeBytes, existingID)
		return existingID, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx, `INSERT INTO media_items(content_id, season, episode, episode_title, quality, audio_lang, subtitle_lang, source_url, size_bytes, created_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
		item.ContentID, item.Season, item.Episode, item.EpisodeTitle, item.Quality, item.AudioLang, item.SubtitleLang, item.SourceURL, item.SizeBytes, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) GetContent(ctx context.Context, id int64) (Content, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, kind, title, normalized_title, original_title, year, overview, poster_url, language, created_by, created_at, updated_at FROM contents WHERE id=?`, id)
	return scanContent(row)
}

func (s *Store) GetMediaWithContent(ctx context.Context, mediaID int64) (Content, MediaItem, error) {
	row := s.db.QueryRowContext(ctx, `SELECT c.id, c.kind, c.title, c.normalized_title, c.original_title, c.year, c.overview, c.poster_url, c.language, c.created_by, c.created_at, c.updated_at,
		m.id, m.content_id, m.season, m.episode, m.episode_title, m.quality, m.audio_lang, m.subtitle_lang, m.source_url, m.size_bytes, m.created_at
		FROM media_items m JOIN contents c ON c.id=m.content_id WHERE m.id=?`, mediaID)
	var c Content
	var m MediaItem
	err := row.Scan(&c.ID, &c.Kind, &c.Title, &c.Normalized, &c.OriginalTitle, &c.Year, &c.Overview, &c.PosterURL, &c.Language, &c.CreatedBy, &c.CreatedAt, &c.UpdatedAt,
		&m.ID, &m.ContentID, &m.Season, &m.Episode, &m.EpisodeTitle, &m.Quality, &m.AudioLang, &m.SubtitleLang, &m.SourceURL, &m.SizeBytes, &m.CreatedAt)
	return c, m, err
}

func (s *Store) GetMovieMedia(ctx context.Context, contentID int64) ([]MediaItem, error) {
	return s.queryMedia(ctx, `SELECT id, content_id, season, episode, episode_title, quality, audio_lang, subtitle_lang, source_url, size_bytes, created_at FROM media_items WHERE content_id=? AND season=0 AND episode=0 ORDER BY id`, contentID)
}

func (s *Store) GetEpisodes(ctx context.Context, contentID int64) ([]MediaItem, error) {
	return s.queryMedia(ctx, `SELECT id, content_id, season, episode, episode_title, quality, audio_lang, subtitle_lang, source_url, size_bytes, created_at FROM media_items WHERE content_id=? AND season>0 AND episode>0 ORDER BY season, episode, id`, contentID)
}

func (s *Store) GetSeasonEpisodes(ctx context.Context, contentID int64, season int) ([]MediaItem, error) {
	return s.queryMedia(ctx, `SELECT id, content_id, season, episode, episode_title, quality, audio_lang, subtitle_lang, source_url, size_bytes, created_at FROM media_items WHERE content_id=? AND season=? AND episode>0 ORDER BY season, episode, id`, contentID, season)
}

func (s *Store) GetSeasons(ctx context.Context, contentID int64) ([]int, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT season FROM media_items WHERE content_id=? AND season>0 ORDER BY season`, contentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var seasons []int
	for rows.Next() {
		var season int
		if err := rows.Scan(&season); err != nil {
			return nil, err
		}
		seasons = append(seasons, season)
	}
	return seasons, rows.Err()
}

func (s *Store) queryMedia(ctx context.Context, query string, args ...any) ([]MediaItem, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []MediaItem
	for rows.Next() {
		var m MediaItem
		if err := rows.Scan(&m.ID, &m.ContentID, &m.Season, &m.Episode, &m.EpisodeTitle, &m.Quality, &m.AudioLang, &m.SubtitleLang, &m.SourceURL, &m.SizeBytes, &m.CreatedAt); err != nil {
			return nil, err
		}
		items = append(items, m)
	}
	return items, rows.Err()
}

func (s *Store) SearchContent(ctx context.Context, query string, limit int) ([]SearchResult, error) {
	q := normalizeTitle(query)
	if q == "" {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `SELECT c.id, c.kind, c.title, c.normalized_title, c.original_title, c.year, c.overview, c.poster_url, c.language, c.created_by, c.created_at, c.updated_at,
		COALESCE(group_concat(a.normalized_alias, '|'), ''), COALESCE(group_concat(a.alias, '|'), '')
		FROM contents c LEFT JOIN content_aliases a ON a.content_id=c.id
		GROUP BY c.id
		ORDER BY c.updated_at DESC
		LIMIT 3000`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	results := make([]SearchResult, 0)
	for rows.Next() {
		var c Content
		var normAliasesRaw string
		var aliasesRaw string
		if err := rows.Scan(&c.ID, &c.Kind, &c.Title, &c.Normalized, &c.OriginalTitle, &c.Year, &c.Overview, &c.PosterURL, &c.Language, &c.CreatedBy, &c.CreatedAt, &c.UpdatedAt, &normAliasesRaw, &aliasesRaw); err != nil {
			return nil, err
		}
		normAliases := splitAliasRaw(normAliasesRaw)
		aliases := splitAliasRaw(aliasesRaw)
		score, exact, matchedAlias := scoreCandidate(q, c.Normalized, normAliases, aliases, c.Year)
		if score >= 250 || exact {
			results = append(results, SearchResult{Content: c, Score: score, Exact: exact, MatchedAlias: matchedAlias})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(results, func(i, j int) bool {
		if results[i].Score != results[j].Score {
			return results[i].Score > results[j].Score
		}
		return results[i].Content.Year > results[j].Content.Year
	})
	if limit > 0 && len(results) > limit {
		results = results[:limit]
	}
	return results, nil
}

func (s *Store) SuggestContent(ctx context.Context, query string, limit int) ([]SearchResult, error) {
	q := normalizeTitle(query)
	if q == "" {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, kind, title, normalized_title, original_title, year, overview, poster_url, language, created_by, created_at, updated_at FROM contents LIMIT 3000`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var results []SearchResult
	for rows.Next() {
		c, err := scanContentRows(rows)
		if err != nil {
			return nil, err
		}
		score := fuzzyScore(q, c.Normalized)
		if score > 120 {
			results = append(results, SearchResult{Content: c, Score: score})
		}
	}
	sort.SliceStable(results, func(i, j int) bool { return results[i].Score > results[j].Score })
	if len(results) > limit {
		results = results[:limit]
	}
	return results, rows.Err()
}

func (s *Store) RecentContents(ctx context.Context, limit int) ([]Content, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, kind, title, normalized_title, original_title, year, overview, poster_url, language, created_by, created_at, updated_at FROM contents ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []Content
	for rows.Next() {
		c, err := scanContentRows(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, c)
	}
	return items, rows.Err()
}

func (s *Store) CreateAccessToken(ctx context.Context, token string, mediaID int64, userID int64, expires time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO access_tokens(token, media_item_id, user_id, expires_at, created_at) VALUES(?,?,?,?,?)`, token, mediaID, userID, expires.UTC().Format(time.RFC3339), nowUTC())
	return err
}

func (s *Store) GetTokenInfo(ctx context.Context, token string) (TokenInfo, error) {
	row := s.db.QueryRowContext(ctx, `SELECT t.token, t.expires_at, t.created_at, t.used_at, t.hits, t.user_id,
		c.id, c.kind, c.title, c.normalized_title, c.original_title, c.year, c.overview, c.poster_url, c.language, c.created_by, c.created_at, c.updated_at,
		m.id, m.content_id, m.season, m.episode, m.episode_title, m.quality, m.audio_lang, m.subtitle_lang, m.source_url, m.size_bytes, m.created_at
		FROM access_tokens t
		JOIN media_items m ON m.id=t.media_item_id
		JOIN contents c ON c.id=m.content_id
		WHERE t.token=?`, token)
	var info TokenInfo
	err := row.Scan(&info.Token, &info.ExpiresAt, &info.CreatedAt, &info.UsedAt, &info.Hits, &info.UserID,
		&info.Content.ID, &info.Content.Kind, &info.Content.Title, &info.Content.Normalized, &info.Content.OriginalTitle, &info.Content.Year, &info.Content.Overview, &info.Content.PosterURL, &info.Content.Language, &info.Content.CreatedBy, &info.Content.CreatedAt, &info.Content.UpdatedAt,
		&info.Media.ID, &info.Media.ContentID, &info.Media.Season, &info.Media.Episode, &info.Media.EpisodeTitle, &info.Media.Quality, &info.Media.AudioLang, &info.Media.SubtitleLang, &info.Media.SourceURL, &info.Media.SizeBytes, &info.Media.CreatedAt)
	return info, err
}

func (s *Store) TouchToken(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE access_tokens SET hits=hits+1, used_at=? WHERE token=?`, nowUTC(), token)
	return err
}

func (s *Store) LogRequest(ctx context.Context, userID int64, query string, contentID int64, mediaID int64, status string, lang string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO requests(user_id, query, normalized_query, matched_content_id, matched_media_id, status, language, created_at) VALUES(?,?,?,?,?,?,?,?)`,
		userID, query, normalizeTitle(query), contentID, mediaID, status, lang, nowUTC())
	return err
}

func (s *Store) DeleteContent(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM contents WHERE id=?`, id)
	return err
}

func (s *Store) SaveExternalCandidate(ctx context.Context, r TorrentSearchResult, userID int64) (int64, error) {
	now := nowUTC()
	res, err := s.db.ExecContext(ctx, `INSERT INTO external_candidates(provider, title, kind, year, quality, source_url, info_url, size_bytes, seeders, created_by, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
		r.Provider, r.Title, firstNonEmpty(r.Kind, KindMovie), r.Year, r.Quality, r.SourceURL, r.InfoURL, r.SizeBytes, r.Seeders, userID, now)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) GetExternalCandidate(ctx context.Context, id int64) (ExternalCandidate, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, provider, title, kind, year, quality, source_url, info_url, size_bytes, seeders, created_by, created_at FROM external_candidates WHERE id=?`, id)
	var c ExternalCandidate
	err := row.Scan(&c.ID, &c.Provider, &c.Title, &c.Kind, &c.Year, &c.Quality, &c.SourceURL, &c.InfoURL, &c.SizeBytes, &c.Seeders, &c.CreatedBy, &c.CreatedAt)
	return c, err
}

func (s *Store) GetExternalCandidates(ctx context.Context, ids []int64) ([]ExternalCandidate, error) {
	out := make([]ExternalCandidate, 0, len(ids))
	for _, id := range ids {
		c, err := s.GetExternalCandidate(ctx, id)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			return out, err
		}
		out = append(out, c)
	}
	return out, nil
}

type Stats struct {
	Users         int64
	Movies        int64
	Series        int64
	MediaItems    int64
	ActiveTokens  int64
	RequestsToday int64
}

func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	queries := []struct {
		q    string
		arg  any
		dest *int64
	}{
		{q: `SELECT COUNT(1) FROM users`, dest: &st.Users},
		{q: `SELECT COUNT(1) FROM contents WHERE kind='movie'`, dest: &st.Movies},
		{q: `SELECT COUNT(1) FROM contents WHERE kind='series'`, dest: &st.Series},
		{q: `SELECT COUNT(1) FROM media_items`, dest: &st.MediaItems},
		{q: `SELECT COUNT(1) FROM access_tokens WHERE expires_at > ?`, arg: nowUTC(), dest: &st.ActiveTokens},
		{q: `SELECT COUNT(1) FROM requests WHERE created_at >= ?`, arg: time.Now().UTC().Format("2006-01-02"), dest: &st.RequestsToday},
	}
	for _, item := range queries {
		var err error
		if item.arg != nil {
			err = s.db.QueryRowContext(ctx, item.q, item.arg).Scan(item.dest)
		} else {
			err = s.db.QueryRowContext(ctx, item.q).Scan(item.dest)
		}
		if err != nil {
			return st, err
		}
	}
	return st, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanContent(row rowScanner) (Content, error) {
	var c Content
	err := row.Scan(&c.ID, &c.Kind, &c.Title, &c.Normalized, &c.OriginalTitle, &c.Year, &c.Overview, &c.PosterURL, &c.Language, &c.CreatedBy, &c.CreatedAt, &c.UpdatedAt)
	return c, err
}

func scanContentRows(rows *sql.Rows) (Content, error) {
	return scanContent(rows)
}

// ───────────────────────────────────────────────────────────────────────────────
// Legal external torrent search providers
// ───────────────────────────────────────────────────────────────────────────────

type TorrentSearchResult struct {
	Provider  string
	Title     string
	Kind      string
	Year      int
	Quality   string
	SourceURL string
	InfoURL   string
	SizeBytes int64
	Seeders   int
}

type TorrentSearchProvider interface {
	Name() string
	Search(ctx context.Context, query string, limit int) ([]TorrentSearchResult, error)
}

type WebTorrentSamplesProvider struct{}

func NewWebTorrentSamplesProvider() *WebTorrentSamplesProvider { return &WebTorrentSamplesProvider{} }
func (p *WebTorrentSamplesProvider) Name() string              { return "webtorrent-samples" }

func (p *WebTorrentSamplesProvider) Search(ctx context.Context, query string, limit int) ([]TorrentSearchResult, error) {
	_ = ctx
	q := normalizeTitle(query)
	samples := []TorrentSearchResult{
		{Provider: p.Name(), Title: "Sintel", Kind: KindMovie, Year: 2010, Quality: "torrent", SourceURL: "https://webtorrent.io/torrents/sintel.torrent", InfoURL: "https://durian.blender.org/"},
		{Provider: p.Name(), Title: "Big Buck Bunny", Kind: KindMovie, Year: 2008, Quality: "torrent", SourceURL: "https://webtorrent.io/torrents/big-buck-bunny.torrent", InfoURL: "https://peach.blender.org/"},
		{Provider: p.Name(), Title: "Tears of Steel", Kind: KindMovie, Year: 2012, Quality: "torrent", SourceURL: "https://webtorrent.io/torrents/tears-of-steel.torrent", InfoURL: "https://mango.blender.org/"},
		{Provider: p.Name(), Title: "Cosmos Laundromat", Kind: KindMovie, Year: 2015, Quality: "torrent", SourceURL: "https://webtorrent.io/torrents/cosmos-laundromat.torrent", InfoURL: "https://gooseberry.blender.org/"},
	}
	var scored []struct {
		item  TorrentSearchResult
		score int
	}
	for _, sample := range samples {
		score := fuzzyScore(q, normalizeTitle(sample.Title))
		if score >= 180 || strings.Contains(normalizeTitle(sample.Title), q) || strings.Contains(q, normalizeTitle(sample.Title)) {
			scored = append(scored, struct {
				item  TorrentSearchResult
				score int
			}{sample, score})
		}
	}
	sort.SliceStable(scored, func(i, j int) bool { return scored[i].score > scored[j].score })
	out := make([]TorrentSearchResult, 0, len(scored))
	for _, item := range scored {
		out = append(out, item.item)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, nil
}

type InternetArchiveProvider struct {
	client *http.Client
}

func NewInternetArchiveProvider() *InternetArchiveProvider {
	return &InternetArchiveProvider{client: &http.Client{Timeout: 20 * time.Second}}
}
func (p *InternetArchiveProvider) Name() string { return "internet-archive" }

type iaSearchResponse struct {
	Response struct {
		Docs []iaDoc `json:"docs"`
	} `json:"response"`
}

type iaDoc struct {
	Identifier string `json:"identifier"`
	Title      string `json:"title"`
	Year       any    `json:"year"`
	Date       string `json:"date"`
	Downloads  int64  `json:"downloads"`
}

func (p *InternetArchiveProvider) Search(ctx context.Context, query string, limit int) ([]TorrentSearchResult, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 6
	}
	v := url.Values{}
	v.Set("q", fmt.Sprintf("title:(%s) AND mediatype:(movies)", iaQuote(query)))
	v.Add("fl[]", "identifier")
	v.Add("fl[]", "title")
	v.Add("fl[]", "year")
	v.Add("fl[]", "date")
	v.Add("fl[]", "downloads")
	v.Set("rows", strconv.Itoa(limit))
	v.Set("page", "1")
	v.Set("output", "json")
	endpoint := "https://archive.org/advancedsearch.php?" + v.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		bb, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("internet archive status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(bb)))
	}
	var out iaSearchResponse
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber()
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	results := make([]TorrentSearchResult, 0, len(out.Response.Docs))
	for _, doc := range out.Response.Docs {
		id := strings.TrimSpace(doc.Identifier)
		if id == "" {
			continue
		}
		title := strings.TrimSpace(doc.Title)
		if title == "" {
			title = id
		}
		results = append(results, TorrentSearchResult{
			Provider:  p.Name(),
			Title:     title,
			Kind:      KindMovie,
			Year:      parseFlexibleYear(doc.Year, doc.Date),
			Quality:   "archive.torrent",
			SourceURL: fmt.Sprintf("https://archive.org/download/%s/%s_archive.torrent", url.PathEscape(id), url.PathEscape(id)),
			InfoURL:   "https://archive.org/details/" + url.PathEscape(id),
			Seeders:   int(doc.Downloads),
		})
	}
	return results, nil
}

func iaQuote(s string) string {
	s = strings.ReplaceAll(s, `"`, "")
	return `"` + s + `"`
}

type RSSProvider struct {
	urls    []string
	allowed map[string]bool
	client  *http.Client
}

func NewRSSProvider(urls []string, allowed map[string]bool) *RSSProvider {
	return &RSSProvider{urls: urls, allowed: allowed, client: &http.Client{Timeout: 25 * time.Second}}
}
func (p *RSSProvider) Name() string { return "rss-configurado" }

type rssFeed struct {
	Channel rssChannel `xml:"channel"`
	Entries []rssItem  `xml:"entry"`
}

type rssChannel struct {
	Items []rssItem `xml:"item"`
}

type rssItem struct {
	Title      string       `xml:"title"`
	Links      []rssLink    `xml:"link"`
	Enclosure  rssEnclosure `xml:"enclosure"`
	PubDate    string       `xml:"pubDate"`
	LengthText string       `xml:"length"`
}

type rssLink struct {
	Text string `xml:",chardata"`
	Href string `xml:"href,attr"`
	Rel  string `xml:"rel,attr"`
	Type string `xml:"type,attr"`
}

type rssEnclosure struct {
	URL    string `xml:"url,attr"`
	Length string `xml:"length,attr"`
	Type   string `xml:"type,attr"`
}

func (p *RSSProvider) Search(ctx context.Context, query string, limit int) ([]TorrentSearchResult, error) {
	if limit <= 0 {
		limit = 6
	}
	q := normalizeTitle(query)
	results := make([]TorrentSearchResult, 0, limit)
	for _, feedURL := range p.urls {
		if len(results) >= limit {
			break
		}
		items, err := p.fetchFeed(ctx, feedURL, query)
		if err != nil {
			continue
		}
		sourceHost := hostOf(expandSearchURL(feedURL, query))
		for _, item := range items {
			if len(results) >= limit {
				break
			}
			title := strings.TrimSpace(item.Title)
			if title == "" || fuzzyScore(q, normalizeTitle(title)) < 170 {
				continue
			}
			source := pickRSSSource(item)
			if source == "" || !torrentSourceAllowed(source, p.allowed, sourceHost) {
				continue
			}
			results = append(results, TorrentSearchResult{
				Provider:  p.Name(),
				Title:     title,
				Kind:      KindMovie,
				Quality:   firstNonEmpty(item.Enclosure.Type, "rss.torrent"),
				SourceURL: source,
				InfoURL:   firstNonEmpty(firstRSSLink(item), source),
				SizeBytes: parseInt64(firstNonEmpty(item.Enclosure.Length, item.LengthText)),
			})
		}
	}
	return results, nil
}

func (p *RSSProvider) fetchFeed(ctx context.Context, rawURL string, query string) ([]rssItem, error) {
	endpoint := expandSearchURL(rawURL, query)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "QooqCinemaBot/1.0 legal-rss")
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("rss status=%d", resp.StatusCode)
	}
	var feed rssFeed
	if err := xml.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&feed); err != nil {
		return nil, err
	}
	items := append([]rssItem{}, feed.Channel.Items...)
	items = append(items, feed.Entries...)
	return items, nil
}

func expandSearchURL(rawURL string, query string) string {
	return strings.ReplaceAll(rawURL, "{query}", url.QueryEscape(query))
}

func pickRSSSource(item rssItem) string {
	if strings.TrimSpace(item.Enclosure.URL) != "" {
		return strings.TrimSpace(item.Enclosure.URL)
	}
	for _, link := range item.Links {
		candidate := strings.TrimSpace(firstNonEmpty(link.Href, strings.TrimSpace(link.Text)))
		if strings.Contains(strings.ToLower(link.Type), "bittorrent") || strings.HasSuffix(strings.ToLower(candidate), ".torrent") || isMagnetURI(candidate) {
			return candidate
		}
	}
	candidate := firstRSSLink(item)
	if isMagnetURI(candidate) || strings.HasSuffix(strings.ToLower(strings.TrimSpace(candidate)), ".torrent") {
		return strings.TrimSpace(candidate)
	}
	return ""
}

func firstRSSLink(item rssItem) string {
	for _, link := range item.Links {
		candidate := strings.TrimSpace(firstNonEmpty(link.Href, strings.TrimSpace(link.Text)))
		if candidate != "" {
			return candidate
		}
	}
	return ""
}

func torrentSourceAllowed(raw string, allowed map[string]bool, fallbackHost string) bool {
	if isMagnetURI(raw) {
		return true
	}
	h := normalizeHost(hostOf(raw))
	if h == "" {
		return false
	}
	if len(allowed) == 0 {
		return h == normalizeHost(fallbackHost)
	}
	return allowed[h] || allowed["*."+h] || allowed["*"]
}

// ───────────────────────────────────────────────────────────────────────────────
// Formatting, keyboards, i18n
// ───────────────────────────────────────────────────────────────────────────────

var i18n = map[string]map[string]string{
	"es": {
		"welcome":             "🎬 Qooq Cine\n\nHola, %s. Envíame el nombre exacto de una película o serie y te devuelvo el enlace seguro del Worker.\n\nEjemplos:\n• Dune: Part Two\n• The Boys\n• La casa del dragón",
		"help":                "🧭 Guía rápida\n\n1. Escribe el título de una película o serie.\n2. Si es película, recibirás un enlace directo.\n3. Si es serie, recibirás capítulos ordenados por temporada.\n4. Usa /lang para cambiar idioma.\n\nComandos: /start /help /catalog /search /lang",
		"admin_short":         "👑 Modo admin activo. Usa /admin para cargar películas y episodios.",
		"admin_help":          "👑 Admin\n\n/addmovie Título | Año | Calidad | URL/magnet | Sinopsis opcional\n/addserie Título | Año | Sinopsis opcional\n/addepisode Serie | Temporada | Episodio | Título episodio | Calidad | URL/magnet\n/bulkepisodes Serie | Temporada\n1 | Episodio uno | 1080p | URL/magnet\n2 | Episodio dos | 1080p | URL/magnet\n/alias content_id | alias 1, alias 2\n/catalog\n/stats\n/deletecontent content_id",
		"choose_lang":         "🌐 Elige tu idioma:",
		"lang_set":            "✅ Idioma actualizado.",
		"banned":              "🚫 No tienes acceso al bot.",
		"unknown_command":     "No reconozco ese comando. Envíame el nombre de una película o usa /help.",
		"not_admin":           "🚫 Esta acción es sólo para administradores.",
		"usage_addmovie":      "Uso:\n/addmovie Título | Año | Calidad | URL/magnet | Sinopsis opcional",
		"usage_addserie":      "Uso:\n/addserie Título | Año | Sinopsis opcional",
		"usage_addepisode":    "Uso:\n/addepisode Serie | Temporada | Episodio | Título episodio | Calidad | URL/magnet",
		"usage_bulkepisodes":  "Uso:\n/bulkepisodes Serie | Temporada\n1 | Episodio uno | 1080p | URL/magnet\n2 | Episodio dos | 1080p | URL/magnet",
		"no_results":          "🔎 No encontré “%s” en el catálogo. Verifica el título o prueba con otro nombre.",
		"suggestions":         "Quizá quisiste decir:",
		"choose_result":       "Encontré varias coincidencias para “%s”. Elige una:",
		"search_again_button": "🔎 Buscar otra",
		"open_link_button":    "▶️ Abrir enlace",
		"ask_search":          "Escribe el nombre exacto de la película o serie que quieres ver.",
		"loading":             "Preparando enlaces…",
		"unavailable":         "⚠️ El título existe, pero todavía no tiene enlaces disponibles.",
	},
	"en": {
		"welcome":             "🎬 Qooq Cinema\n\nHi, %s. Send me the exact movie or series title and I will return a secure Worker link.\n\nExamples:\n• Dune: Part Two\n• The Boys\n• House of the Dragon",
		"help":                "🧭 Quick guide\n\n1. Type a movie or series title.\n2. For movies, you get a direct link.\n3. For series, episodes are grouped by season.\n4. Use /lang to change language.\n\nCommands: /start /help /catalog /search /lang",
		"admin_short":         "👑 Admin mode enabled. Use /admin to add movies and episodes.",
		"admin_help":          "👑 Admin\n\n/addmovie Title | Year | Quality | URL/magnet | Optional overview\n/addserie Title | Year | Optional overview\n/addepisode Series | Season | Episode | Episode title | Quality | URL/magnet\n/bulkepisodes Series | Season\n1 | Episode one | 1080p | URL/magnet\n2 | Episode two | 1080p | URL/magnet\n/alias content_id | alias 1, alias 2\n/catalog\n/stats\n/deletecontent content_id",
		"choose_lang":         "🌐 Choose your language:",
		"lang_set":            "✅ Language updated.",
		"banned":              "🚫 You do not have access to this bot.",
		"unknown_command":     "I do not recognize that command. Send me a movie title or use /help.",
		"not_admin":           "🚫 Admin only.",
		"usage_addmovie":      "Usage:\n/addmovie Title | Year | Quality | URL/magnet | Optional overview",
		"usage_addserie":      "Usage:\n/addserie Title | Year | Optional overview",
		"usage_addepisode":    "Usage:\n/addepisode Series | Season | Episode | Episode title | Quality | URL/magnet",
		"usage_bulkepisodes":  "Usage:\n/bulkepisodes Series | Season\n1 | Episode one | 1080p | URL/magnet\n2 | Episode two | 1080p | URL/magnet",
		"no_results":          "🔎 I could not find “%s” in the catalog. Check the title or try another name.",
		"suggestions":         "Maybe you meant:",
		"choose_result":       "I found multiple matches for “%s”. Pick one:",
		"search_again_button": "🔎 Search again",
		"open_link_button":    "▶️ Open link",
		"ask_search":          "Type the exact movie or series title you want to watch.",
		"loading":             "Preparing links…",
		"unavailable":         "⚠️ This title exists but has no links yet.",
	},
	"pt": {
		"welcome":             "🎬 Qooq Cinema\n\nOlá, %s. Envie o nome exato de um filme ou série e eu devolvo um link seguro do Worker.",
		"help":                "🧭 Guia rápido\n\nEscreva o título. Filmes recebem um link direto; séries recebem episódios por temporada. Use /search para fontes externas legais e /lang para mudar idioma.",
		"admin_short":         "👑 Modo admin ativo. Use /admin para adicionar conteúdo.",
		"admin_help":          "👑 Admin\n/addmovie Título | Ano | Qualidade | URL/magnet | Sinopse\n/addserie Título | Ano | Sinopse\n/addepisode Série | Temporada | Episódio | Título | Qualidade | URL/magnet\n/bulkepisodes Série | Temporada\n1 | Episódio | 1080p | URL/magnet",
		"choose_lang":         "🌐 Escolha seu idioma:",
		"lang_set":            "✅ Idioma atualizado.",
		"banned":              "🚫 Sem acesso.",
		"unknown_command":     "Comando desconhecido. Envie o nome de um filme ou use /help.",
		"not_admin":           "🚫 Apenas admin.",
		"usage_addmovie":      "Uso: /addmovie Título | Ano | Qualidade | URL/magnet | Sinopse",
		"usage_addserie":      "Uso: /addserie Título | Ano | Sinopse",
		"usage_addepisode":    "Uso: /addepisode Série | Temporada | Episódio | Título | Qualidade | URL/magnet",
		"usage_bulkepisodes":  "Uso: /bulkepisodes Série | Temporada\n1 | Episódio | 1080p | URL/magnet",
		"no_results":          "🔎 Não encontrei “%s” no catálogo.",
		"suggestions":         "Talvez você quis dizer:",
		"choose_result":       "Encontrei várias opções para “%s”. Escolha uma:",
		"search_again_button": "🔎 Buscar outra",
		"open_link_button":    "▶️ Abrir link",
		"ask_search":          "Digite o nome exato do filme ou série.",
		"loading":             "Preparando links…",
		"unavailable":         "⚠️ Título sem links disponíveis.",
	},
	"fr": {
		"welcome":             "🎬 Qooq Cinéma\n\nBonjour, %s. Envoie le titre exact d’un film ou d’une série et je te renvoie un lien Worker sécurisé.",
		"help":                "🧭 Guide rapide\n\nÉcris le titre. Les films reçoivent un lien direct; les séries sont groupées par saison. Utilise /search pour sources externes légales et /lang pour changer la langue.",
		"admin_short":         "👑 Mode admin actif. Utilise /admin pour ajouter du contenu.",
		"admin_help":          "👑 Admin\n/addmovie Titre | Année | Qualité | URL/magnet | Synopsis\n/addserie Titre | Année | Synopsis\n/addepisode Série | Saison | Épisode | Titre | Qualité | URL/magnet\n/bulkepisodes Série | Saison\n1 | Épisode | 1080p | URL/magnet",
		"choose_lang":         "🌐 Choisis ta langue:",
		"lang_set":            "✅ Langue mise à jour.",
		"banned":              "🚫 Accès refusé.",
		"unknown_command":     "Commande inconnue. Envoie un titre ou utilise /help.",
		"not_admin":           "🚫 Admin seulement.",
		"usage_addmovie":      "Utilisation: /addmovie Titre | Année | Qualité | URL/magnet | Synopsis",
		"usage_addserie":      "Utilisation: /addserie Titre | Année | Synopsis",
		"usage_addepisode":    "Utilisation: /addepisode Série | Saison | Épisode | Titre | Qualité | URL/magnet",
		"usage_bulkepisodes":  "Utilisation: /bulkepisodes Série | Saison\n1 | Épisode | 1080p | URL/magnet",
		"no_results":          "🔎 Je n’ai pas trouvé “%s” dans le catalogue.",
		"suggestions":         "Tu voulais peut-être dire:",
		"choose_result":       "J’ai trouvé plusieurs résultats pour “%s”. Choisis:",
		"search_again_button": "🔎 Chercher encore",
		"open_link_button":    "▶️ Ouvrir le lien",
		"ask_search":          "Écris le titre exact du film ou de la série.",
		"loading":             "Préparation des liens…",
		"unavailable":         "⚠️ Titre sans liens disponibles.",
	},
}

func (a *App) tr(lang string, key string) string {
	lang = normalizeLang(lang)
	if m, ok := i18n[lang]; ok {
		if v, ok := m[key]; ok {
			return v
		}
	}
	if v, ok := i18n["es"][key]; ok {
		return v
	}
	return key
}

func mainKeyboard(lang string, admin bool) *tgbotapi.InlineKeyboardMarkup {
	labels := map[string][]string{
		"es": {"🔎 Buscar", "🌐 Idioma", "❓ Ayuda", "⚙️ Admin"},
		"en": {"🔎 Search", "🌐 Language", "❓ Help", "⚙️ Admin"},
		"pt": {"🔎 Buscar", "🌐 Idioma", "❓ Ajuda", "⚙️ Admin"},
		"fr": {"🔎 Chercher", "🌐 Langue", "❓ Aide", "⚙️ Admin"},
	}
	l := labels[normalizeLang(lang)]
	if len(l) == 0 {
		l = labels["es"]
	}
	rows := [][]tgbotapi.InlineKeyboardButton{
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(l[0], "search"), tgbotapi.NewInlineKeyboardButtonData(l[1], "choose_lang")),
		tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(l[2], "help")),
	}
	if admin {
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(l[3], "admin")))
	}
	kb := tgbotapi.NewInlineKeyboardMarkup(rows...)
	return &kb
}

func languageKeyboard() *tgbotapi.InlineKeyboardMarkup {
	kb := tgbotapi.NewInlineKeyboardMarkup(
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("🇪🇸 Español", "lang:es"),
			tgbotapi.NewInlineKeyboardButtonData("🇺🇸 English", "lang:en"),
		),
		tgbotapi.NewInlineKeyboardRow(
			tgbotapi.NewInlineKeyboardButtonData("🇧🇷 Português", "lang:pt"),
			tgbotapi.NewInlineKeyboardButtonData("🇫🇷 Français", "lang:fr"),
		),
	)
	return &kb
}

func seasonsKeyboard(lang string, contentID int64, seasons []int, includeAll bool) tgbotapi.InlineKeyboardMarkup {
	rows := make([][]tgbotapi.InlineKeyboardButton, 0)
	row := make([]tgbotapi.InlineKeyboardButton, 0, 4)
	for _, season := range seasons {
		row = append(row, tgbotapi.NewInlineKeyboardButtonData(fmt.Sprintf("T%d", season), fmt.Sprintf("season:%d:%d", contentID, season)))
		if len(row) == 4 {
			rows = append(rows, row)
			row = nil
		}
	}
	if len(row) > 0 {
		rows = append(rows, row)
	}
	if includeAll {
		label := "📦 Todo"
		if normalizeLang(lang) == "en" {
			label = "📦 All"
		}
		rows = append(rows, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(label, fmt.Sprintf("all:%d", contentID))))
	}
	return tgbotapi.NewInlineKeyboardMarkup(rows...)
}

func formatMovieCard(lang string, c Content, m MediaItem, link string, exp time.Time) string {
	var sb strings.Builder
	sb.WriteString("🎬 ")
	sb.WriteString(c.Title)
	if c.Year > 0 {
		sb.WriteString(fmt.Sprintf(" (%d)", c.Year))
	}
	sb.WriteString("\n")
	if c.Overview != "" {
		sb.WriteString("\n")
		sb.WriteString(c.Overview)
		sb.WriteString("\n")
	}
	if m.Quality != "" {
		sb.WriteString("\n🏷 ")
		sb.WriteString(m.Quality)
	}
	if m.AudioLang != "" {
		sb.WriteString("\n🌐 Audio: ")
		sb.WriteString(strings.ToUpper(m.AudioLang))
	}
	sb.WriteString("\n\n🔗 ")
	sb.WriteString(link)
	sb.WriteString("\n⏳ ")
	if normalizeLang(lang) == "en" {
		sb.WriteString("Expires: ")
	} else {
		sb.WriteString("Expira: ")
	}
	sb.WriteString(exp.Local().Format("2006-01-02 15:04"))
	return sb.String()
}

func formatSeriesIntro(lang string, c Content, total int, seasons []int, max int) string {
	var sb strings.Builder
	sb.WriteString("📺 ")
	sb.WriteString(c.Title)
	if c.Year > 0 {
		sb.WriteString(fmt.Sprintf(" (%d)", c.Year))
	}
	sb.WriteString("\n\n")
	if normalizeLang(lang) == "en" {
		sb.WriteString(fmt.Sprintf("This series has %d episodes. To avoid sending too many links at once, choose a season. Limit per full request: %d.\n", total, max))
	} else {
		sb.WriteString(fmt.Sprintf("Esta serie tiene %d episodios. Para evitar demasiados enlaces de golpe, elige una temporada. Límite por petición completa: %d.\n", total, max))
	}
	sb.WriteString("\nTemporadas: ")
	for i, s := range seasons {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString(fmt.Sprintf("T%d", s))
	}
	return sb.String()
}

func formatSeriesLinks(lang string, c Content, links []EpisodeLink, seasonFilter int) []string {
	var chunks []string
	var sb strings.Builder
	writeHeader := func() {
		sb.WriteString("📺 ")
		sb.WriteString(c.Title)
		if c.Year > 0 {
			sb.WriteString(fmt.Sprintf(" (%d)", c.Year))
		}
		if seasonFilter > 0 {
			sb.WriteString(fmt.Sprintf(" — Temporada %d", seasonFilter))
		}
		sb.WriteString("\n")
		if c.Overview != "" && seasonFilter == 0 {
			sb.WriteString("\n")
			sb.WriteString(c.Overview)
			sb.WriteString("\n")
		}
	}
	writeHeader()
	currentSeason := -1
	for _, ep := range links {
		line := ""
		if ep.Item.Season != currentSeason {
			currentSeason = ep.Item.Season
			line += fmt.Sprintf("\n━━━━━━━━━━━━\n📦 Temporada %d\n", currentSeason)
		}
		line += fmt.Sprintf("\n%s — %s", episodeCode(ep.Item.Season, ep.Item.Episode), nonEmpty(ep.Item.EpisodeTitle, "Episodio"))
		if ep.Item.Quality != "" {
			line += " [" + ep.Item.Quality + "]"
		}
		line += "\n" + ep.URL + "\n"
		if sb.Len()+len(line) > MaxTelegramText {
			chunks = append(chunks, sb.String())
			sb.Reset()
			writeHeader()
			currentSeason = -1
		}
		sb.WriteString(line)
		currentSeason = ep.Item.Season
	}
	if normalizeLang(lang) == "en" {
		sb.WriteString("\n⏳ Links are temporary. Request the title again if one expires.")
	} else {
		sb.WriteString("\n⏳ Los enlaces son temporales. Vuelve a pedir el título si alguno expira.")
	}
	if strings.TrimSpace(sb.String()) != "" {
		chunks = append(chunks, sb.String())
	}
	return chunks
}

// ───────────────────────────────────────────────────────────────────────────────
// Search, normalization, language detection
// ───────────────────────────────────────────────────────────────────────────────

func normalizeTitle(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = removeAccents(s)
	s = strings.ReplaceAll(s, "&", " and ")
	s = regexp.MustCompile(`(?i)\b(4k|1080p|720p|2160p|bluray|web[- ]?dl|hdr|dvdrip|latino|castellano|subtitulado)\b`).ReplaceAllString(s, " ")
	var b strings.Builder
	lastSpace := false
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
			lastSpace = false
			continue
		}
		if !lastSpace {
			b.WriteByte(' ')
			lastSpace = true
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}

func removeAccents(s string) string {
	replacer := strings.NewReplacer(
		"á", "a", "à", "a", "ä", "a", "â", "a", "ã", "a", "å", "a",
		"é", "e", "è", "e", "ë", "e", "ê", "e",
		"í", "i", "ì", "i", "ï", "i", "î", "i",
		"ó", "o", "ò", "o", "ö", "o", "ô", "o", "õ", "o",
		"ú", "u", "ù", "u", "ü", "u", "û", "u",
		"ñ", "n", "ç", "c",
	)
	return replacer.Replace(s)
}

func scoreCandidate(q string, title string, normAliases []string, aliases []string, year int) (score int, exact bool, matchedAlias string) {
	names := append([]string{title}, normAliases...)
	bestScore := 0
	bestExact := false
	bestAlias := ""
	for idx, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		cur := fuzzyScore(q, name)
		if name == q || stripYear(name) == stripYear(q) {
			cur += 1000
			bestExact = true
		}
		if strings.Contains(q, strconv.Itoa(year)) && year > 0 {
			cur += 100
		}
		if cur > bestScore {
			bestScore = cur
			if idx > 0 && idx-1 < len(aliases) {
				bestAlias = aliases[idx-1]
			}
		}
	}
	return bestScore, bestExact, bestAlias
}

func fuzzyScore(q string, name string) int {
	if q == "" || name == "" {
		return 0
	}
	score := 0
	if name == q {
		score += 1000
	}
	if strings.HasPrefix(name, q) || strings.HasPrefix(q, name) {
		score += 350
	}
	if strings.Contains(name, q) || strings.Contains(q, name) {
		score += 250
	}
	qTokens := strings.Fields(q)
	covered := 0
	for _, tok := range qTokens {
		if strings.Contains(name, tok) {
			covered++
		}
	}
	if len(qTokens) > 0 {
		score += int(float64(covered) / float64(len(qTokens)) * 260)
	}
	d := levenshtein(q, name)
	maxLen := maxInt(runeLen(q), runeLen(name))
	if maxLen > 0 {
		sim := 1.0 - float64(d)/float64(maxLen)
		if sim > 0 {
			score += int(sim * 260)
		}
	}
	return score
}

func stripYear(s string) string {
	return strings.TrimSpace(regexp.MustCompile(`\b(19|20)\d{2}\b`).ReplaceAllString(s, ""))
}

func levenshtein(a, b string) int {
	ra := []rune(a)
	rb := []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 0
			if ra[i-1] != rb[j-1] {
				cost = 1
			}
			cur[j] = minInt(cur[j-1]+1, minInt(prev[j]+1, prev[j-1]+cost))
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}

func detectLanguage(tgLang string, text string, fallback string) string {
	textNorm := " " + normalizeTitle(text) + " "
	scores := map[string]int{}
	wordLists := map[string][]string{
		"es": {" la ", " el ", " los ", " una ", " pelicula ", " serie ", " temporada ", " capitulo ", " quiero ", " buscar "},
		"en": {" the ", " movie ", " series ", " season ", " episode ", " watch ", " search ", " want "},
		"pt": {" filme ", " serie ", " temporada ", " episodio ", " quero ", " procurar ", " assistir "},
		"fr": {" film ", " serie ", " saison ", " episode ", " regarder ", " chercher "},
	}
	for lang, words := range wordLists {
		for _, w := range words {
			if strings.Contains(textNorm, w) {
				scores[lang]++
			}
		}
	}
	bestLang := ""
	bestScore := 0
	for lang, score := range scores {
		if score > bestScore {
			bestLang = lang
			bestScore = score
		}
	}
	if bestScore > 0 {
		return bestLang
	}
	if lang := normalizeLang(tgLang); isSupportedLang(lang) {
		return lang
	}
	if lang := normalizeLang(fallback); isSupportedLang(lang) {
		return lang
	}
	return "es"
}

func normalizeLang(lang string) string {
	lang = strings.ToLower(strings.TrimSpace(lang))
	lang = strings.ReplaceAll(lang, "_", "-")
	if strings.HasPrefix(lang, "en") {
		return "en"
	}
	if strings.HasPrefix(lang, "pt") {
		return "pt"
	}
	if strings.HasPrefix(lang, "fr") {
		return "fr"
	}
	return "es"
}

func isSupportedLang(lang string) bool {
	switch normalizeLang(lang) {
	case "es", "en", "pt", "fr":
		return true
	default:
		return false
	}
}

// ───────────────────────────────────────────────────────────────────────────────
// Helpers
// ───────────────────────────────────────────────────────────────────────────────

func signToken(secret string, raw string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(raw))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil)[:16])
	return raw + "." + sig
}

func verifySignedToken(secret string, signed string) bool {
	parts := strings.Split(signed, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return false
	}
	expected := signToken(secret, parts[0])
	return hmac.Equal([]byte(expected), []byte(signed))
}

func randomBase64(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

func parseAdminIDs(raw string) map[int64]bool {
	ids := make(map[int64]bool)
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, err := strconv.ParseInt(part, 10, 64)
		if err == nil && id > 0 {
			ids[id] = true
		}
	}
	return ids
}

func parseLogLevel(raw string) slog.Level {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case "DEBUG":
		return slog.LevelDebug
	case "WARN", "WARNING":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		v = strings.TrimSpace(v)
		if v != "" {
			return v
		}
	}
	return ""
}

func mustAtoi(raw string, fallback int) int {
	v, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return fallback
	}
	return v
}

func parseBool(raw string) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes", "y", "on", "si", "sí":
		return true
	default:
		return false
	}
}

func splitCSV(raw string) []string {
	raw = strings.ReplaceAll(raw, "\n", ",")
	raw = strings.ReplaceAll(raw, ";", ",")
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" || seen[part] {
			continue
		}
		seen[part] = true
		out = append(out, part)
	}
	return out
}

func parseHostSet(raw string) map[string]bool {
	items := splitCSV(raw)
	out := make(map[string]bool, len(items))
	for _, item := range items {
		if item == "*" {
			out["*"] = true
			continue
		}
		out[normalizeHost(item)] = true
	}
	return out
}

func hostOf(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return ""
	}
	return u.Host
}

func normalizeHost(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	raw = strings.TrimPrefix(raw, "http://")
	raw = strings.TrimPrefix(raw, "https://")
	if h, _, err := strings.Cut(raw, "/"); err {
		raw = h
	}
	if h, _, err := strings.Cut(raw, ":"); err {
		raw = h
	}
	raw = strings.TrimPrefix(raw, "www.")
	return raw
}

func parseInt64(raw string) int64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0
	}
	return v
}

func parseFlexibleYear(values ...any) int {
	for _, value := range values {
		s := strings.TrimSpace(fmt.Sprint(value))
		if s == "" || s == "<nil>" {
			continue
		}
		m := regexp.MustCompile(`\b(18|19|20)\d{2}\b`).FindString(s)
		if m == "" {
			continue
		}
		y, err := strconv.Atoi(m)
		if err == nil {
			return y
		}
	}
	return 0
}

func humanBytes(n int64) string {
	if n <= 0 {
		return "0 B"
	}
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	v := float64(n)
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d %s", n, units[i])
	}
	return fmt.Sprintf("%.1f %s", v, units[i])
}

func nowUTC() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func splitPipes(s string) []string {
	raw := strings.Split(s, "|")
	parts := make([]string, 0, len(raw))
	for _, p := range raw {
		p = strings.TrimSpace(p)
		if p != "" {
			parts = append(parts, p)
		}
	}
	return parts
}

func validateSourceURL(raw string) error {
	raw = strings.TrimSpace(raw)
	if isMagnetURI(raw) {
		if !strings.Contains(strings.ToLower(raw), "xt=urn:btih:") {
			return errors.New("magnet URI must include xt=urn:btih")
		}
		return nil
	}
	u, err := url.ParseRequestURI(raw)
	if err != nil {
		return err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("scheme %q not allowed; use http, https or magnet", u.Scheme)
	}
	if u.Host == "" {
		return errors.New("missing host")
	}
	return nil
}

func isMagnetURI(raw string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(raw)), "magnet:?")
}

func isTorrentFileURL(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	return strings.HasSuffix(strings.ToLower(u.Path), ".torrent")
}

func splitAliasRaw(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	items := strings.Split(raw, "|")
	out := make([]string, 0, len(items))
	for _, item := range items {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func splitLong(text string, max int) []string {
	if len(text) <= max {
		return []string{text}
	}
	var chunks []string
	for len(text) > max {
		cut := max
		if idx := strings.LastIndex(text[:max], "\n"); idx > 0 {
			cut = idx
		} else if idx := strings.LastIndex(text[:max], " "); idx > 0 {
			cut = idx
		}
		chunks = append(chunks, strings.TrimSpace(text[:cut]))
		text = strings.TrimSpace(text[cut:])
	}
	if strings.TrimSpace(text) != "" {
		chunks = append(chunks, strings.TrimSpace(text))
	}
	return chunks
}

func bestEpisodeItems(items []MediaItem) []MediaItem {
	best := make(map[string]MediaItem)
	for _, item := range items {
		key := fmt.Sprintf("%d:%d", item.Season, item.Episode)
		old, ok := best[key]
		if !ok || qualityRank(item.Quality) > qualityRank(old.Quality) {
			best[key] = item
		}
	}
	out := make([]MediaItem, 0, len(best))
	for _, item := range best {
		out = append(out, item)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Season != out[j].Season {
			return out[i].Season < out[j].Season
		}
		return out[i].Episode < out[j].Episode
	})
	return out
}

func qualityRank(q string) int {
	q = strings.ToLower(q)
	switch {
	case strings.Contains(q, "8k"):
		return 8000
	case strings.Contains(q, "4k") || strings.Contains(q, "2160"):
		return 4000
	case strings.Contains(q, "1440"):
		return 1440
	case strings.Contains(q, "1080"):
		return 1080
	case strings.Contains(q, "720"):
		return 720
	case strings.Contains(q, "480"):
		return 480
	default:
		return 1
	}
}

func episodeCode(season int, episode int) string {
	return fmt.Sprintf("S%02dE%02d", season, episode)
}

func kindEmoji(kind string) string {
	if kind == KindSeries {
		return "📺"
	}
	return "🎬"
}

func isProbablyVideo(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	path := strings.ToLower(u.Path)
	for _, ext := range []string{".mp4", ".webm", ".m4v", ".mov", ".m3u8", ".mkv", ".avi", ".ts", ".vob"} {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	return false
}

func isVideoExt(ext string) bool {
	ext = strings.ToLower(strings.TrimPrefix(ext, "."))
	switch ext {
	case "avi", "mkv", "mp4", "webm", "m4v", "ts", "vob", "mov", "m3u8":
		return true
	default:
		return false
	}
}

func isAudioExt(ext string) bool {
	ext = strings.ToLower(strings.TrimPrefix(ext, "."))
	switch ext {
	case "mp3", "wav", "ogg", "flac", "m4a", "aac", "opus":
		return true
	default:
		return false
	}
}

func nonEmpty(v string, fallback string) string {
	if strings.TrimSpace(v) != "" {
		return v
	}
	return fallback
}

func runeLen(s string) int {
	return len([]rune(s))
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
