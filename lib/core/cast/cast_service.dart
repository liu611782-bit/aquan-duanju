import 'cast_controller.dart';
import 'cast_profile.dart';
import 'cast_recipe.dart';
import 'cast_target.dart';

/// 投屏全局单例：控制器跨页面存活（迷你窗/详情页切换不掉会话），
/// 设备记忆（最近/钉选）由调用方经 CastStore 持久化。
class CastService {
  CastService._();

  static final CastService instance = CastService._();

  final CastController controller = CastController();

  /// M3-4：把 CastStore 的配方/画像表接到控制器（修复配方持久化未接线，
  /// AC-14 跨启动命中依赖这里）。bootstrap 加载完 CastStore 后调用一次；
  /// 未调用时控制器用内存表（不落盘）。
  void attachStores({
    required CastRecipeStore recipes,
    CastProfileStore? profiles,
  }) {
    controller.recipes = recipes;
    controller.profiles = profiles;
  }

  /// 设备排序：钉选 > 最近使用 > 在线 > 名称（协议无关，按 target id）。
  List<CastTarget> sortDevices(
    Iterable<CastTarget> devices, {
    required Set<String> pinnedIds,
    String? lastId,
  }) {
    final list = List.of(devices);
    int rank(CastTarget d) {
      if (pinnedIds.contains(d.id)) return 0;
      if (d.id == lastId) return 1;
      return d.online ? 2 : 3;
    }

    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.name.compareTo(b.name);
    });
    return list;
  }
}
