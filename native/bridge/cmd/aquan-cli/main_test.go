package main

import (
	"reflect"
	"testing"
)

func TestSplitArgs(t *testing.T) {
	opt := splitArgs([]string{"持械入宋", "--limit", "3", "--json"}, options{limit: 10})
	if got := opt.positional; !reflect.DeepEqual(got, []string{"持械入宋"}) {
		t.Fatalf("positional = %v, want [持械入宋]", got)
	}
	if opt.limit != 3 {
		t.Fatalf("limit = %d, want 3", opt.limit)
	}
	if !opt.json {
		t.Fatal("json = false, want true")
	}
}

func TestSplitArgsLimitBounds(t *testing.T) {
	if got := splitArgs([]string{"--limit", "-5", "x"}, options{limit: 10}).limit; got != 10 {
		t.Fatalf("limit = %d, want 10 (负数回落默认)", got)
	}
	if got := splitArgs([]string{"--limit", "999", "x"}, options{limit: 10}).limit; got != 50 {
		t.Fatalf("limit = %d, want 50 (上限截断)", got)
	}
}

func TestScoreAndBestMatch(t *testing.T) {
	items := []item{
		{ID: "1", Title: "持械入宋：第五季"},
		{ID: "2", Title: "持械入宋"},
		{ID: "3", Title: "完全无关的剧"},
	}
	best := bestMatch("持械入宋", items)
	if best == nil || best.ID != "2" {
		t.Fatalf("best = %+v, want ID 2（完全匹配优先）", best)
	}
	if got := score("无关", "完全无关的剧"); got <= 0 {
		t.Fatalf("score = %d, want > 0（包含也算命中）", got)
	}
}

func TestNorm(t *testing.T) {
	if norm("  持械 入宋 ") != "持械入宋" {
		t.Fatalf("norm 处理空格失败")
	}
}

func TestControlSummaryCast(t *testing.T) {
	if got := controlSummary("cast", map[string]any{"ok": true}); got != "已恢复上次投屏" {
		t.Fatalf("cast summary = %q", got)
	}
	if got := controlSummary("cast_stop", map[string]any{"ok": true}); got != "已断开投屏" {
		t.Fatalf("cast_stop summary = %q", got)
	}
	if got := controlSummary("cast", map[string]any{"ok": false, "error": "没有可恢复的投屏记录，或恢复失败"}); got != "失败：没有可恢复的投屏记录，或恢复失败" {
		t.Fatalf("cast failure summary = %q", got)
	}
}

func TestIsAllDigits(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"7701350814786259993", true},
		{"12345", true},
		{"", false},
		{"万妖图录传", false},
		{"12abc", false},
		{"12 3", false},
	}
	for _, c := range cases {
		if got := isAllDigits(c.in); got != c.want {
			t.Fatalf("isAllDigits(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}
