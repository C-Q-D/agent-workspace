//! CLI 模式的动态工作区终端矩阵。
//!
//! 本模块以中央区域真实可用尺寸计算近方形网格；卡片低于可读尺寸前切换为分页，
//! 不把窗口数量固定为 3×3，也不通过无限压缩容纳全部终端。

use gpui::{
    AnyElement, App, ClickEvent, Context, FontWeight, InteractiveElement, IntoElement,
    ParentElement, Styled, Window, div, prelude::*, px, svg,
};
use paneflow_config::schema::WorkspaceGridDensity;

use crate::PaneFlowApp;

/// 卡片之间及矩阵外侧的统一间距。
const GRID_GAP: f32 = 8.0;
/// 分页控制行占用的高度。
const GRID_PAGER_HEIGHT: f32 = 34.0;

/// 一次布局规划使用的最小可读卡片尺寸。
///
/// 该值只参与纯几何计算，不改变工作区、PTY 或终端 Surface 生命周期。
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct WorkspaceGridMetrics {
    /// 卡片最小宽度。
    min_width: f32,
    /// 卡片最小高度；包含固定 28px 标题栏和终端输出区。
    min_height: f32,
}

impl WorkspaceGridMetrics {
    /// 把稳定产品密度映射为像素阈值；Auto 必须始终保持历史尺寸。
    const fn for_density(density: WorkspaceGridDensity) -> Self {
        match density {
            WorkspaceGridDensity::Auto => Self {
                min_width: 320.0,
                min_height: 190.0,
            },
            WorkspaceGridDensity::Comfortable => Self {
                min_width: 400.0,
                min_height: 240.0,
            },
            WorkspaceGridDensity::Compact => Self {
                min_width: 260.0,
                min_height: 150.0,
            },
        }
    }
}

/// 一次渲染帧使用的确定性矩阵计划。
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct WorkspaceGridPlan {
    /// 当前页列数。
    pub(crate) columns: usize,
    /// 当前页行数。
    pub(crate) rows: usize,
    /// 单页最多工作区数。
    pub(crate) page_size: usize,
    /// 总页数。
    pub(crate) page_count: usize,
    /// 已按总页数夹紧的当前页。
    pub(crate) page: usize,
    /// 每个卡片的实际高度。
    pub(crate) cell_height: f32,
}

impl WorkspaceGridPlan {
    /// 根据工作区数量和中央区域尺寸计算近方形分页计划。
    pub(crate) fn calculate(
        workspace_count: usize,
        available_width: f32,
        available_height: f32,
        requested_page: usize,
        metrics: WorkspaceGridMetrics,
    ) -> Self {
        let count = workspace_count.max(1);
        let ideal_columns = integer_ceil_sqrt(count);
        let max_columns = ((available_width + GRID_GAP) / (metrics.min_width + GRID_GAP))
            .floor()
            .max(1.0) as usize;
        let columns = ideal_columns.min(max_columns).max(1);

        let needed_rows = count.div_ceil(columns);
        let full_height_rows = ((available_height + GRID_GAP) / (metrics.min_height + GRID_GAP))
            .floor()
            .max(1.0) as usize;
        let initial_rows = needed_rows.min(full_height_rows).max(1);
        let initial_page_size = columns.saturating_mul(initial_rows).max(1);
        let needs_pager = count > initial_page_size;
        let grid_height = if needs_pager {
            (available_height - GRID_PAGER_HEIGHT).max(metrics.min_height)
        } else {
            available_height.max(metrics.min_height)
        };
        let max_rows = ((grid_height + GRID_GAP) / (metrics.min_height + GRID_GAP))
            .floor()
            .max(1.0) as usize;
        let rows = needed_rows.min(max_rows).max(1);
        let page_size = columns.saturating_mul(rows).max(1);
        let page_count = workspace_count.max(1).div_ceil(page_size);
        let page = requested_page.min(page_count.saturating_sub(1));
        let cell_height = ((grid_height - GRID_GAP * (rows.saturating_sub(1) as f32))
            / rows as f32)
            .max(metrics.min_height);

        Self {
            columns,
            rows,
            page_size,
            page_count,
            page,
            cell_height,
        }
    }

    /// 判断指定工作区索引是否位于本计划的当前页。
    fn contains_workspace(self, workspace_index: usize) -> bool {
        let start = self.page.saturating_mul(self.page_size);
        workspace_index >= start && workspace_index < start.saturating_add(self.page_size)
    }

    /// 返回包含目标工作区索引的页码。
    fn page_for_workspace(self, workspace_index: usize) -> usize {
        workspace_index / self.page_size.max(1)
    }
}

/// 仅使用整数运算计算向上取整平方根，避免浮点边界影响 9、16 等关键容量。
fn integer_ceil_sqrt(value: usize) -> usize {
    let mut root = 1usize;
    while root.saturating_mul(root) < value {
        root = root.saturating_add(1);
    }
    root
}

impl PaneFlowApp {
    /// 渲染当前矩阵页的真实工作区布局和分页控制。
    pub(crate) fn render_workspace_grid(
        &mut self,
        window: &mut Window,
        available_width: f32,
        available_height: f32,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 配置 watcher 已把最新合法配置放入内存；这里只做常数时间枚举映射，
        // 不在渲染路径读取磁盘，也不触发终端重建。
        let metrics =
            WorkspaceGridMetrics::for_density(self.cached_config.resolved_workspace_grid_density());
        let sizing_plan = WorkspaceGridPlan::calculate(
            self.workspaces.len(),
            available_width,
            available_height,
            self.workspace_grid_page,
            metrics,
        );
        let requested_page = self
            .workspace_focus
            .take_reveal_workspace_id()
            .and_then(|workspace_id| {
                self.workspaces
                    .iter()
                    .position(|workspace| workspace.id == workspace_id)
            })
            .map_or(sizing_plan.page, |index| {
                sizing_plan.page_for_workspace(index)
            });
        let plan = WorkspaceGridPlan::calculate(
            self.workspaces.len(),
            available_width,
            available_height,
            requested_page,
            metrics,
        );
        self.workspace_grid_page = plan.page;
        let start = plan.page.saturating_mul(plan.page_size);
        let end = (start + plan.page_size).min(self.workspaces.len());

        // 每次布局渲染都同步可见性，确保 IPC 新增窗格也会在下一帧继承所在页策略。
        // 终端内部对相同状态切换会直接返回，不会产生额外重绘通知。
        for (index, workspace) in self.workspaces.iter_mut().enumerate() {
            workspace.set_grid_page_visible(plan.contains_workspace(index), cx);
        }

        let app_weak = cx.weak_entity();
        let on_resize_end = std::rc::Rc::new(move |cx: &mut App| {
            let _ = app_weak.update(cx, |app, cx| app.save_session(cx));
        });
        let mut grid = div()
            .grid()
            // GPUI 的网格列数使用 u16；渲染边界显式夹紧，避免异常超宽视口发生截断。
            .grid_cols(plan.columns.min(u16::MAX as usize) as u16)
            .gap(px(GRID_GAP))
            .w_full()
            .p(px(GRID_GAP));

        for idx in start..end {
            let workspace = &self.workspaces[idx];
            let workspace_id = workspace.id;
            let title = workspace.title.clone();
            let is_active = idx == self.active_idx;
            let terminal = workspace.root.as_ref().map_or_else(
                || {
                    div()
                        .flex()
                        .items_center()
                        .justify_center()
                        .size_full()
                        .text_color(ui.muted)
                        .child("No terminal panes open")
                        .into_any_element()
                },
                |root| root.render(window, cx, Some(on_resize_end.clone())),
            );

            let card = div()
                .id(gpui::SharedString::from(format!(
                    "workspace-grid-{workspace_id}"
                )))
                .h(px(plan.cell_height))
                .min_w_0()
                .overflow_hidden()
                .flex()
                .flex_col()
                .border_1()
                .border_color(if is_active { ui.accent } else { ui.border })
                .rounded(px(6.))
                .bg(ui.base)
                .child(
                    div()
                        .id(gpui::SharedString::from(format!(
                            "workspace-grid-header-{workspace_id}"
                        )))
                        .h(px(28.))
                        .flex_none()
                        .px(px(9.))
                        .flex()
                        .items_center()
                        .justify_between()
                        .cursor_pointer()
                        .bg(if is_active { ui.subtle } else { ui.surface })
                        .hover(|style| style.bg(crate::theme::ui_colors().subtle))
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                            if let Some(index) = this
                                .workspaces
                                .iter()
                                .position(|workspace| workspace.id == workspace_id)
                            {
                                this.select_workspace(index, window, cx);
                            }
                        }))
                        .child(
                            div()
                                .min_w_0()
                                .overflow_hidden()
                                .whitespace_nowrap()
                                .text_ellipsis()
                                .text_size(px(11.))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(ui.text)
                                .child(title),
                        )
                        .child(
                            div()
                                .id(gpui::SharedString::from(format!(
                                    "workspace-grid-maximize-{workspace_id}"
                                )))
                                .size(px(22.))
                                .flex_none()
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded(px(4.))
                                .text_color(ui.muted)
                                .hover(|style| style.bg(crate::theme::ui_colors().base))
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                    cx.stop_propagation();
                                    if let Some(index) = this
                                        .workspaces
                                        .iter()
                                        .position(|workspace| workspace.id == workspace_id)
                                    {
                                        this.maximize_workspace_at(index, window, cx);
                                    }
                                }))
                                .child(
                                    svg()
                                        .size(px(11.))
                                        .path("icons/generic_maximize.svg")
                                        .text_color(ui.muted),
                                ),
                        ),
                )
                .child(div().flex_1().min_h_0().overflow_hidden().child(terminal));
            grid = grid.child(card);
        }

        let mut root = div()
            .size_full()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(ui.base)
            .child(div().flex_1().min_h_0().overflow_hidden().child(grid));
        if plan.page_count > 1 {
            let previous_enabled = plan.page > 0;
            let next_enabled = plan.page + 1 < plan.page_count;
            root = root.child(
                div()
                    .h(px(GRID_PAGER_HEIGHT))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .gap(px(10.))
                    .text_size(px(11.))
                    .text_color(ui.muted)
                    .child(
                        page_button("workspace-grid-previous", "Previous", previous_enabled, ui)
                            .on_click(cx.listener(move |this, _: &ClickEvent, _window, cx| {
                                if previous_enabled {
                                    this.workspace_grid_page =
                                        this.workspace_grid_page.saturating_sub(1);
                                    cx.notify();
                                }
                            })),
                    )
                    .child(format!("{} / {}", plan.page + 1, plan.page_count))
                    .child(
                        page_button("workspace-grid-next", "Next", next_enabled, ui).on_click(
                            cx.listener(move |this, _: &ClickEvent, _window, cx| {
                                if next_enabled {
                                    this.workspace_grid_page =
                                        this.workspace_grid_page.saturating_add(1);
                                    cx.notify();
                                }
                            }),
                        ),
                    ),
            );
        }
        root.into_any_element()
    }

    /// 渲染单个应用级放大工作区；其他工作区继续运行但关闭终端重绘。
    pub(crate) fn render_maximized_workspace(
        &mut self,
        window: &mut Window,
        available_width: f32,
        available_height: f32,
        ui: crate::theme::UiColors,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(workspace_id) = self.workspace_focus.workspace_id() else {
            return self.render_workspace_grid(window, available_width, available_height, ui, cx);
        };
        let Some(index) = self
            .workspaces
            .iter()
            .position(|workspace| workspace.id == workspace_id)
        else {
            // 生命周期原子会在关闭入口主动清理；这里保留防御性回退，避免空白主区域。
            self.workspace_focus.clear();
            return self.render_workspace_grid(window, available_width, available_height, ui, cx);
        };

        for (workspace_index, workspace) in self.workspaces.iter_mut().enumerate() {
            workspace.set_grid_page_visible(workspace_index == index, cx);
        }
        let title = self.workspaces[index].title.clone();
        let app_weak = cx.weak_entity();
        let on_resize_end = std::rc::Rc::new(move |cx: &mut App| {
            let _ = app_weak.update(cx, |app, cx| app.save_session(cx));
        });
        let terminal = self.workspaces[index].root.as_ref().map_or_else(
            || {
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .size_full()
                    .text_color(ui.muted)
                    .child("No terminal panes open")
                    .into_any_element()
            },
            |root| root.render(window, cx, Some(on_resize_end)),
        );

        div()
            .size_full()
            .min_h_0()
            .flex()
            .flex_col()
            .bg(ui.base)
            .child(
                div()
                    .h(px(32.))
                    .flex_none()
                    .px(px(10.))
                    .flex()
                    .items_center()
                    .justify_between()
                    .border_b_1()
                    .border_color(ui.border)
                    .bg(ui.surface)
                    .child(
                        div()
                            .min_w_0()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .text_size(px(11.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(ui.text)
                            .child(title),
                    )
                    .child(
                        div()
                            .id("workspace-grid-restore")
                            .size(px(24.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .cursor_pointer()
                            .rounded(px(4.))
                            .text_color(ui.muted)
                            .hover(|style| style.bg(crate::theme::ui_colors().subtle))
                            .on_click(cx.listener(|this, _: &ClickEvent, _window, cx| {
                                cx.stop_propagation();
                                this.restore_workspace_grid(cx);
                            }))
                            .child(
                                svg()
                                    .size(px(12.))
                                    .path("icons/generic_restore.svg")
                                    .text_color(ui.muted),
                            ),
                    ),
            )
            .child(div().flex_1().min_h_0().overflow_hidden().child(terminal))
            .into_any_element()
    }
}

/// 渲染一个轻量分页按钮；禁用状态不改变页码。
fn page_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    ui: crate::theme::UiColors,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px(px(10.))
        .py(px(4.))
        .rounded(px(5.))
        .text_color(if enabled { ui.text } else { ui.muted })
        .bg(if enabled { ui.subtle } else { ui.base })
        .when(enabled, |button| {
            button
                .cursor_pointer()
                .hover(|style| style.bg(crate::theme::ui_colors().surface))
        })
        .child(label)
}

#[cfg(test)]
mod tests {
    use super::{WorkspaceGridMetrics, WorkspaceGridPlan};
    use paneflow_config::schema::WorkspaceGridDensity;

    /// 生成指定密度的纯几何阈值，避免测试依赖应用实体或终端。
    fn metrics(density: WorkspaceGridDensity) -> WorkspaceGridMetrics {
        WorkspaceGridMetrics::for_density(density)
    }

    #[test]
    fn wide_viewport_reaches_one_two_three_and_four_square_grids() {
        let viewport = (1_700.0, 930.0);
        for (count, expected) in [(1, 1), (4, 2), (9, 3), (16, 4)] {
            let plan = WorkspaceGridPlan::calculate(
                count,
                viewport.0,
                viewport.1,
                0,
                metrics(WorkspaceGridDensity::Auto),
            );
            assert_eq!(plan.columns, expected, "{count} 个窗口的列数");
            assert_eq!(plan.rows, expected, "{count} 个窗口的行数");
            assert_eq!(plan.page_count, 1, "{count} 个窗口应在宽屏单页显示");
        }
    }

    #[test]
    fn narrow_viewport_pages_instead_of_compressing_below_readable_size() {
        let plan = WorkspaceGridPlan::calculate(
            16,
            1_050.0,
            720.0,
            99,
            metrics(WorkspaceGridDensity::Auto),
        );

        assert_eq!(plan.columns, 3);
        assert_eq!(plan.rows, 3);
        assert_eq!(plan.page_size, 9);
        assert_eq!(plan.page_count, 2);
        assert_eq!(plan.page, 1);
        assert!(plan.cell_height >= 190.0);
        assert!(!plan.contains_workspace(8));
        assert!(plan.contains_workspace(9));
        assert!(plan.contains_workspace(15));
        assert_eq!(plan.page_for_workspace(0), 0);
        assert_eq!(plan.page_for_workspace(8), 0);
        assert_eq!(plan.page_for_workspace(9), 1);
        assert_eq!(plan.page_for_workspace(15), 1);
    }

    #[test]
    fn density_changes_capacity_without_removing_readability_floors() {
        let viewport = (1_100.0, 720.0);
        let comfortable = WorkspaceGridPlan::calculate(
            16,
            viewport.0,
            viewport.1,
            usize::MAX,
            metrics(WorkspaceGridDensity::Comfortable),
        );
        let auto = WorkspaceGridPlan::calculate(
            16,
            viewport.0,
            viewport.1,
            usize::MAX,
            metrics(WorkspaceGridDensity::Auto),
        );
        let compact = WorkspaceGridPlan::calculate(
            16,
            viewport.0,
            viewport.1,
            usize::MAX,
            metrics(WorkspaceGridDensity::Compact),
        );

        assert_eq!(
            (comfortable.columns, comfortable.rows, comfortable.page_size),
            (2, 2, 4)
        );
        assert_eq!((auto.columns, auto.rows, auto.page_size), (3, 3, 9));
        assert_eq!(
            (compact.columns, compact.rows, compact.page_size),
            (4, 4, 16)
        );
        assert_eq!(comfortable.page, 3);
        assert_eq!(auto.page, 1);
        assert_eq!(compact.page, 0);
        assert!(comfortable.cell_height >= 240.0);
        assert!(auto.cell_height >= 190.0);
        assert!(compact.cell_height >= 150.0);
    }
}
