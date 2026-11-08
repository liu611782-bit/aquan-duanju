// Command aquan-cli 是阿圈短剧的命令行入口，给 AI 助手 / 脚本使用。
//
//	aquan-cli search 持械入宋 [--limit 10] [--json]  只查列表，不打开窗口
//	aquan-cli watch  持械入宋                         搜索并挑最匹配的一部开播
//	aquan-cli series <ID>                            直接开播这一部（有历史就续播）
//	aquan-cli pause|resume|toggle|next|prev          指挥正在播放的窗口
//	aquan-cli status                                 当前在播什么、播到哪
//
// 它复用 native/bridge/core 的方法表（/search 走 openhongguo SDK），
// 与图形界面使用同一套接口与错误码。搜到的列表只在本次输出里有效，
// 下一步请把输出里的 ID 传给 series。播放控制经单实例通道发给已运行的
// 窗口（端口写在 %AppData%\aquan-duanju\instance.json），窗口没开时报错。
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/wjsqqj/aquan-core/core"
)

const usage = `阿圈短剧命令行入口（供 AI 助手 / 脚本使用）

用法：
  aquan-cli search <关键词> [--limit 10] [--filter short|comic|ai] [--json]
      只查一次搜索列表，打印到 stdout 后退出，不打开窗口。
  aquan-cli watch <关键词>
      搜索并挑标题最匹配的一部开播（与裸参数等价）。
  aquan-cli series <剧集ID> [--episode N]
      打开并直接播放这一部；有观看历史时从上次那一集那一秒续播，
      指定 --episode 则从第 N 集开播。
  aquan-cli pause | resume | toggle | next | prev
      指挥正在播放的窗口（暂停/继续/播放暂停切换/下一集/上一集）。
  aquan-cli seek <秒 | mm:ss | +30 | -15>
      跳转进度：纯数字按秒绝对跳转，带 +/- 相对当前，也认 mm:ss。
  aquan-cli volume <0-100 | up | down>
      设置音量；up/down 在当前基础上 ±10。
  aquan-cli speed <倍速>
      调倍速（0.5-3.0），按剧记忆。
  aquan-cli quality <清晰度>
      切清晰度（如 1080p / 720p，或 best / worst）；status --json 里看当前值。
  aquan-cli open
      把主窗口唤起到前台（不改变播放状态）。
  aquan-cli status
      当前在播什么、播到哪一集哪一秒；没在播放时也会说明。

选项：
  --limit N     搜索结果条数，默认 10，最多 50
  --filter F    搜索内容筛选：short=真人剧、comic=漫剧、ai=AI 剧
  --episode N   series 命令从第 N 集开播
  --json        以 JSON 输出（search 输出结果；控制命令输出回包）
  --app PATH    指定阿圈短剧可执行文件（默认找同目录下的 aquan_duanju）
`

type item struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	EpisodeCount int    `json:"episode_count"`
}

type page struct {
	Items   []item `json:"items"`
	Cursor  string `json:"cursor"`
	HasMore bool   `json:"has_more"`
}

type envelope struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	switch cmd {
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	case "version", "--version", "-v":
		fmt.Println(core.Version)
		return
	case "search":
		if err := runSearch(args); err != nil {
			fail(err)
		}
	case "watch":
		if err := runWatch(args); err != nil {
			fail(err)
		}
	case "series":
		if err := runSeries(args); err != nil {
			fail(err)
		}
	case "cast":
		// cast              → 恢复上次投屏（跨天重新解析）
		// cast stop         → 断开投屏
		// cast <ID> [--episode N] → 把指定剧集投到上次设备
		rest := splitArgs(args, options{limit: 10}).positional
		if len(rest) > 0 && rest[0] == "stop" {
			if err := runControl("cast_stop", "", nil); err != nil {
				fail(err)
			}
			return
		}
		if len(rest) > 0 {
			opt := splitArgs(args, options{limit: 10})
			payload := map[string]any{
				"kind":    "cast_series",
				"value":   rest[0],
				"episode": opt.episode,
			}
			reply, err := sendCommand(payload)
			if err != nil {
				if errors.Is(err, errNotRunning) {
					fail(errors.New("阿圈短剧没在运行；先启动应用再投屏"))
				}
				fail(err)
			}
			if !opt.json {
				fmt.Println(controlSummary("cast_series", reply))
				return
			}
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			_ = enc.Encode(reply)
			return
		}
		if err := runControl("cast", "", nil); err != nil {
			fail(err)
		}
	case "pause", "resume", "toggle", "next", "prev", "status", "open":
		if err := runControl(cmd, "", args); err != nil {
			fail(err)
		}
	case "seek", "volume", "speed", "quality":
		if err := runControl(cmd, joinRest(splitArgs(args, options{limit: 10}).positional), nil); err != nil {
			fail(err)
		}
	default:
		// 裸参数等价于 watch。
		if err := runWatch(os.Args[1:]); err != nil {
			fail(err)
		}
	}
}

func joinRest(parts []string) string {
	return strings.TrimSpace(strings.Join(parts, " "))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "搜索失败："+err.Error())
	os.Exit(1)
}

// runControl 把播放控制命令发给已运行的窗口。窗口没开（端口连不上）时
// 明确告诉调用方，而不是静默失败。value 是 seek/volume/speed 的参数。
func runControl(kind, value string, args []string) error {
	var opt options
	if args != nil {
		opt = splitArgs(args, options{limit: 10})
	} else {
		opt = splitArgs(nil, options{limit: 10})
	}
	payload := map[string]any{"kind": kind}
	if value != "" {
		payload["value"] = value
	}
	reply, err := sendCommand(payload)
	if err != nil {
		if errors.Is(err, errNotRunning) {
			return fmt.Errorf("阿圈短剧没在运行；先用 watch 或 series 打开一部剧，再发 %s", kind)
		}
		return err
	}
	if !opt.json {
		fmt.Println(controlSummary(kind, reply))
		return nil
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(reply)
}

// controlSummary 把回包翻译成一句话。
func controlSummary(kind string, reply map[string]any) string {
	if ok, _ := reply["ok"].(bool); !ok {
		if msg, _ := reply["error"].(string); msg != "" {
			return "失败：" + msg
		}
		return "失败：未知错误"
	}
	if msg, _ := reply["message"].(string); msg != "" {
		return msg
	}
	switch kind {
	case "cast":
		return "已恢复上次投屏"
	case "cast_stop":
		return "已断开投屏"
	case "pause":
		return "已暂停"
	case "resume":
		return "继续播放"
	case "toggle":
		if playing, _ := reply["playing"].(bool); playing {
			return "继续播放"
		}
		return "已暂停"
	case "next":
		return "已切到下一集"
	case "prev":
		return "已切到上一集"
	case "status":
		series, _ := reply["series"].(string)
		episode, _ := reply["episode"].(float64)
		position, _ := reply["position"].(string)
		duration, _ := reply["duration"].(string)
		playing, _ := reply["playing"].(bool)
		state := "播放中"
		if !playing {
			state = "已暂停"
		}
		return fmt.Sprintf("%s · 第%.0f集 %s/%s（%s）", series, episode, position, duration, state)
	case "seek":
		if pos, _ := reply["position"].(string); pos != "" {
			return "已跳转到 " + pos
		}
		return "已跳转"
	case "volume":
		if volume, _ := reply["volume"].(float64); volume > 0 {
			return fmt.Sprintf("音量 %.0f%%", volume)
		}
		return "已调整音量"
	case "speed":
		if speed, _ := reply["speed"].(float64); speed > 0 {
			return fmt.Sprintf("倍速 %.2gx", speed)
		}
		return "已调整倍速"
	case "quality":
		if q, _ := reply["quality"].(string); q != "" {
			return "已切换到 " + q
		}
		return "已切换清晰度"
	case "open":
		return "窗口已置顶"
	}
	return "已完成"
}

// errNotRunning 表示端口文件不存在或连不上：主窗口没在运行。
var errNotRunning = errors.New("not running")

// sendCommand 与主窗口的单实例端口通信：发一行 JSON，收一行 JSON 回包。
func sendCommand(payload map[string]any) (map[string]any, error) {
	port, err := runningPort()
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		800*time.Millisecond)
	if err != nil {
		return nil, errNotRunning
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return nil, err
	}
	if err := json.NewEncoder(conn).Encode(payload); err != nil {
		return nil, err
	}
	// 关闭写半边，服务端读到 EOF 才处理。
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.CloseWrite()
	}
	var reply map[string]any
	if err := json.NewDecoder(conn).Decode(&reply); err != nil {
		return nil, fmt.Errorf("主窗口无响应：%v", err)
	}
	return reply, nil
}

// runningPort 从固定路径的 instance.json 读主窗口端口（与 App 的
// UserConfigDir/aquan-duanju 约定一致）。
func runningPort() (int, error) {
	raw, err := os.ReadFile(filepath.Join(configDir(), "instance.json"))
	if err != nil {
		return 0, errNotRunning
	}
	var info struct {
		Port int `json:"port"`
	}
	if err := json.Unmarshal(raw, &info); err != nil || info.Port <= 0 {
		return 0, errNotRunning
	}
	return info.Port, nil
}

// splitArgs 把参数分成位置参数与开关：开关可以出现在关键词前后
// （标准库 flag 遇到第一个位置参数就停止解析，`search 剧名 --limit 5` 会被误当成关键词）。
type options struct {
	positional []string
	limit      int
	json       bool
	app        string
	episode    int
	filter     string
}

func splitArgs(args []string, defaults options) options {
	out := defaults
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--limit", "-limit":
			if i+1 < len(args) {
				i++
				if n, err := strconv.Atoi(args[i]); err == nil {
					out.limit = n
				}
			}
		case "--episode", "-episode":
			if i+1 < len(args) {
				i++
				if n, err := strconv.Atoi(args[i]); err == nil && n > 0 {
					out.episode = n
				}
			}
		case "--app", "-app":
			if i+1 < len(args) {
				i++
				out.app = args[i]
			}
		case "--filter", "-filter":
			if i+1 < len(args) {
				i++
				out.filter = args[i]
			}
		case "--json", "-json":
			out.json = true
		default:
			out.positional = append(out.positional, args[i])
		}
	}
	if out.limit <= 0 {
		out.limit = 10
	}
	if out.limit > 50 {
		out.limit = 50
	}
	return out
}

// searchFilters 把 --filter 的短名映射为 SDK 的搜索筛选值；空表示综合。
func searchFilters(name string) []string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "short", "真人剧":
		return []string{"content_type_short_play"}
	case "comic", "漫剧":
		return []string{"content_type_dynamic_comic"}
	case "ai", "ai剧", "AI剧":
		return []string{"content_type_ai_dynamic_comic"}
	}
	return nil
}

func runSearch(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	query := strings.TrimSpace(strings.Join(opt.positional, " "))
	if query == "" {
		return errors.New("缺少搜索关键词")
	}
	p, err := search(query, opt.limit, searchFilters(opt.filter))
	if err != nil {
		return err
	}
	if opt.json {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(p)
	}
	printPage(query, p, opt.limit)
	return nil
}

func runWatch(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	query := strings.TrimSpace(strings.Join(opt.positional, " "))
	if query == "" {
		return errors.New("缺少搜索关键词")
	}
	p, err := search(query, opt.limit, searchFilters(opt.filter))
	if err != nil {
		return err
	}
	best := bestMatch(query, p.Items)
	if best == nil {
		return fmt.Errorf("没有搜到《%s》的可用结果", query)
	}
	fmt.Printf("正在播放《%s》  ID %s\n", best.Title, best.ID)
	return launchApp(opt.app, best.ID, 0)
}

func runSeries(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	if len(opt.positional) == 0 || strings.TrimSpace(opt.positional[0]) == "" {
		return errors.New("缺少剧集 ID")
	}
	return launchApp(opt.app, strings.TrimSpace(opt.positional[0]), opt.episode)
}

func search(query string, limit int, filters []string) (*page, error) {
	profile := filepath.Join(configDir(), "aquan-cli-device.json")
	envRaw := core.New(profile, "")
	var env envelope
	if err := json.Unmarshal([]byte(envRaw), &env); err != nil {
		return nil, fmt.Errorf("核心返回无法解析：%v", err)
	}
	if env.Error != nil {
		return nil, errors.New(env.Error.Message)
	}
	var created struct {
		Handle int32 `json:"handle"`
	}
	if err := json.Unmarshal(env.Result, &created); err != nil {
		return nil, err
	}
	if filters == nil {
		filters = []string{}
	}
	argsJSON, _ := json.Marshal([]any{
		query,
		map[string]any{"cursor": "", "tab": "", "filters": filters, "pageSize": limit},
	})
	raw := core.Call(created.Handle, "search", string(argsJSON))
	var out envelope
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, fmt.Errorf("核心返回无法解析：%v", err)
	}
	if out.Error != nil {
		return nil, errors.New(out.Error.Message)
	}
	var p page
	if err := json.Unmarshal(out.Result, &p); err != nil {
		return nil, err
	}
	if len(p.Items) > limit {
		p.Items = p.Items[:limit]
	}
	return &p, nil
}

func printPage(query string, p *page, limit int) {
	if len(p.Items) == 0 {
		fmt.Printf("没搜到《%s》的结果\n", query)
		return
	}
	exact := false
	for _, it := range p.Items {
		if norm(it.Title) == norm(query) {
			exact = true
			break
		}
	}
	if exact {
		fmt.Printf("%s · %d 条结果，显示前 %d 条\n", query, len(p.Items), limit)
	} else {
		fmt.Printf("没搜到精确匹配的《%s》，以下是接近的结果（%d 条，显示前 %d 条）\n",
			query, len(p.Items), limit)
	}
	for i, it := range p.Items {
		fmt.Printf("%2d  %s  ID %s  %d集\n", i+1, it.Title, it.ID, it.EpisodeCount)
	}
}

func bestMatch(query string, items []item) *item {
	if len(items) == 0 {
		return nil
	}
	type scored struct {
		it    item
		score int
	}
	list := make([]scored, 0, len(items))
	for _, it := range items {
		list = append(list, scored{it, score(query, it.Title)})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].score > list[j].score })
	if list[0].score == 0 {
		// 没有字面相近的，仍按接口返回的第一条（站点推荐位）。
		return &items[0]
	}
	return &list[0].it
}

func score(query, title string) int {
	q, t := norm(query), norm(title)
	switch {
	case q == t:
		return 100
	case strings.HasPrefix(t, q):
		return 80
	case strings.Contains(t, q):
		return 60
	}
	// 关键词被拆成多段（如「持械 入宋」）时按命中字数打分。
	hit := 0
	for _, r := range q {
		if strings.ContainsRune(t, r) {
			hit++
		}
	}
	if hit == 0 {
		return 0
	}
	return 20 + hit*10/len([]rune(q))
}

func norm(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), ""))
}

func configDir() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "aquan-duanju")
}

func launchApp(explicit, seriesID string, episode int) error {
	app := explicit
	if app == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		dir := filepath.Dir(exe)
		name := "aquan_duanju"
		if filepath.Ext(exe) == ".exe" {
			name += ".exe"
		}
		app = filepath.Join(dir, name)
	}
	if _, err := os.Stat(app); err != nil {
		return fmt.Errorf("找不到阿圈短剧主程序：%s（可用 --app 指定）", app)
	}
	cmdArgs := []string{"--series", seriesID}
	if episode > 0 {
		cmdArgs = append(cmdArgs, "--episode", strconv.Itoa(episode))
	}
	cmd := exec.Command(app, cmdArgs...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	return nil
}
