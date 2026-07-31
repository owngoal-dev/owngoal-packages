(() => {
  const grid = document.getElementById("package-grid");
  const count = document.getElementById("packages-count");

  const slugOf = (repository) =>
    repository
      .replace(/^https?:\/\/github\.com\//, "")
      .replace(/^git@github\.com:/, "")
      .replace(/\.git$/, "")
      .replace(/\/$/, "");

  const manifestUrlOf = (slug) =>
    `https://raw.githubusercontent.com/${slug}/HEAD/manifest.json`;

  const cardOf = (pkg) => {
    const card = document.createElement("a");
    card.className = "package-card";
    card.href = pkg.homepage;
    card.target = "_blank";
    card.rel = "noreferrer";

    if (pkg.icon) {
      const icon = document.createElement("img");
      icon.className = "package-icon";
      icon.src = pkg.icon;
      icon.alt = "";
      icon.width = 40;
      icon.height = 40;
      icon.loading = "lazy";
      card.append(icon);
    } else {
      const fallback = document.createElement("span");
      fallback.className = "package-fallback";
      fallback.setAttribute("aria-hidden", "true");
      fallback.textContent = pkg.name[0].toUpperCase();
      card.append(fallback);
    }

    const copy = document.createElement("span");
    copy.className = "package-copy";

    const name = document.createElement("span");
    name.className = "package-name";
    name.textContent = pkg.name;

    const description = document.createElement("span");
    description.className = "package-desc";
    description.textContent = pkg.description || "";

    copy.append(name, description);

    const arrow = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    arrow.setAttribute("viewBox", "0 0 24 24");
    arrow.setAttribute("aria-hidden", "true");
    arrow.innerHTML = '<path d="M7 17 17 7"></path><path d="M8 7h9v9"></path>';

    card.append(copy, arrow);
    return card;
  };

  const showStatus = (html) => {
    grid.innerHTML = "";
    const status = document.createElement("p");
    status.className = "packages-status";
    status.innerHTML = html;
    grid.append(status);
  };

  const load = async () => {
    const index = await (await fetch("./manifest.json")).json();
    const slugs = index.packages.map((entry) => slugOf(entry.repository));

    const results = await Promise.allSettled(
      slugs.map(async (slug) => {
        const response = await fetch(manifestUrlOf(slug));
        if (!response.ok) {
          throw new Error(`${slug}: HTTP ${response.status}`);
        }

        const manifest = await response.json();
        if (typeof manifest.name !== "string" || !manifest.name) {
          throw new Error(`${slug}: manifest has no name`);
        }

        return {
          name: manifest.name,
          description: manifest.description,
          icon: manifest.icon,
          homepage: manifest.homepage || `https://github.com/${slug}`,
        };
      }),
    );

    const packages = [];
    for (const result of results) {
      if (result.status === "fulfilled") {
        packages.push(result.value);
      } else {
        console.warn("Skipping package:", result.reason);
      }
    }

    if (packages.length === 0) {
      throw new Error("No package manifest could be loaded.");
    }

    packages.sort((a, b) =>
      a.name.localeCompare(b.name, "en", { sensitivity: "base" }),
    );

    grid.innerHTML = "";
    for (const pkg of packages) {
      grid.append(cardOf(pkg));
    }

    count.textContent = String(packages.length).padStart(2, "0");
  };

  load().catch((error) => {
    console.error(error);
    showStatus(
      'Package list is unavailable right now — browse on <a href="https://github.com/owngoal-dev">GitHub</a>.',
    );
  });
})();
