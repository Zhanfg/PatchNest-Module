export function setupPullToRefresh(element, onRefresh) {
    let startY = 0;
    let currentY = 0;
    let pulling = false;
    let refreshing = false;
    const threshold = 130;
    const maxPull = 170;

    const container = document.createElement('div');
    container.className = 'ptr-indicator';
    container.innerHTML = `
        <div class="ptr-indicator-wrapper">
            <md-circular-progress value="0" class="ptr-progress"></md-circular-progress>
        </div>
    `;

    element.parentElement.insertBefore(container, element);

    const progress = container.querySelector('.ptr-progress');

    element.addEventListener('touchstart', (e) => {
        // Only single-finger gestures trigger the pull-to-refresh.
        // With multiple touches, e.touches[0] can switch fingers between
        // touchstart and touchmove, causing visible jumps in the indicator.
        if (e.touches.length !== 1) {
            pulling = false;
            return;
        }
        if (element.scrollTop <= 0 && !refreshing) {
            startY = e.touches[0].pageY;
            pulling = true;
            container.style.transition = 'none';
        }
    }, { passive: true });

    element.addEventListener('touchmove', (e) => {
        if (!pulling) return;
        // Re-check multi-touch during move; if a second finger lands, abort.
        if (e.touches.length !== 1) {
            pulling = false;
            container.style.opacity = '0';
            container.style.transform = `translateY(0) scale(0)`;
            return;
        }
        currentY = e.touches[0].pageY;
        const diff = currentY - startY;

        if (diff > 0) {
            if (e.cancelable) e.preventDefault();

            const pullDistance = Math.min(diff * 0.5, maxPull);
            const scale = Math.min(diff / 50, 1);
            container.style.transform = `translateY(${pullDistance}px) scale(${scale})`;
            container.style.opacity = Math.min(diff / 50, 1);
            const progressValue = Math.max(0, Math.min((diff - 50) / (threshold - 50), 1));
            progress.value = progressValue;
        } else {
            pulling = false;
            container.style.opacity = '0';
            container.style.transform = `translateY(0) scale(0)`;
        }
    }, { passive: false });

    element.addEventListener('touchcancel', () => {
        // Finger left the surface unexpectedly — reset everything.
        pulling = false;
        container.style.transition = 'all 0.3s ease';
        container.style.transform = `translateY(0) scale(0)`;
        container.style.opacity = '0';
    });

    element.addEventListener('touchend', async () => {
        if (!pulling) return;
        pulling = false;
        const diff = currentY - startY;

        if (diff > threshold) {
            refreshing = true;
            progress.indeterminate = true;
            container.style.transition = 'all 0.3s ease';
            container.style.transform = `translateY(${threshold * 0.5}px) scale(1)`;
            container.style.opacity = '1';

            try {
                await onRefresh();
            } finally {
                refreshing = false;
                progress.indeterminate = false;
                progress.value = 0;
                container.style.transform = `translateY(0) scale(0)`;
                container.style.opacity = '0';
            }
        } else {
            container.style.transition = 'all 0.3s ease';
            container.style.transform = `translateY(0) scale(0)`;
            container.style.opacity = '0';
        }
    });
}
