import * as d3 from "../../vendor/d3.min.js"

const STATUS_COLORS = {
  deployed: "#22c55e",
  started: "#22c55e",
  active: "#22c55e",
  suspended: "#eab308",
  stopped: "#eab308",
  pending: "#3b82f6",
  error: "#ef4444",
  destroyed: "#6b7280",
  disabled: "#6b7280",
  created: "#3b82f6",
}

const NODE_SIZES = {
  app: { width: 120, height: 40 },
  machine: { radius: 20 },
  volume: { width: 16, height: 24 },
}

function getStatusColor(status) {
  return STATUS_COLORS[status] || "#6b7280"
}

const TopologyHook = {
  mounted() {
    this.svg = null
    this.simulation = null
    this.graphData = { nodes: [], links: [] }

    this.handleEvent("topology_data", (data) => {
      this.graphData = data
      this.render()
    })

    this.handleEvent("topology_update", (changes) => {
      this.applyUpdate(changes)
    })
  },

  destroyed() {
    if (this.simulation) {
      this.simulation.stop()
    }
  },

  render() {
    const container = this.el
    const width = container.clientWidth
    const height = container.clientHeight

    // Clear previous
    d3.select(container).selectAll("svg").remove()

    if (this.graphData.nodes.length === 0) {
      d3.select(container)
        .append("div")
        .attr("class", "flex items-center justify-center h-full text-base-content/40")
        .html('<div class="text-center"><p class="text-lg font-medium">No infrastructure data</p><p class="text-sm mt-1">Add a provider and wait for sync to populate the topology</p></div>')
      return
    }

    this.svg = d3.select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height])

    // Zoom behavior
    const g = this.svg.append("g")
    const zoom = d3.zoom()
      .scaleExtent([0.1, 4])
      .on("zoom", (event) => g.attr("transform", event.transform))
    this.svg.call(zoom)

    // Build region groups for hull backgrounds
    const regions = {}
    this.graphData.nodes.forEach(n => {
      if (n.region) {
        if (!regions[n.region]) regions[n.region] = []
        regions[n.region].push(n)
      }
    })

    // Links
    const link = g.append("g")
      .attr("class", "links")
      .selectAll("line")
      .data(this.graphData.links)
      .join("line")
      .attr("stroke", "oklch(0.7 0.02 250)")
      .attr("stroke-opacity", 0.4)
      .attr("stroke-width", 1.5)
      .attr("stroke-dasharray", d => d.type === "attached_to" ? "4,2" : null)

    // Nodes
    const node = g.append("g")
      .attr("class", "nodes")
      .selectAll("g")
      .data(this.graphData.nodes)
      .join("g")
      .attr("cursor", "pointer")
      .call(d3.drag()
        .on("start", (event, d) => {
          if (!event.active) this.simulation.alphaTarget(0.3).restart()
          d.fx = d.x
          d.fy = d.y
        })
        .on("drag", (event, d) => {
          d.fx = event.x
          d.fy = event.y
        })
        .on("end", (event, d) => {
          if (!event.active) this.simulation.alphaTarget(0)
          d.fx = null
          d.fy = null
        })
      )

    // Draw shapes based on type
    node.each(function(d) {
      const el = d3.select(this)

      if (d.type === "app") {
        // Rounded rectangle for apps
        el.append("rect")
          .attr("width", NODE_SIZES.app.width)
          .attr("height", NODE_SIZES.app.height)
          .attr("x", -NODE_SIZES.app.width / 2)
          .attr("y", -NODE_SIZES.app.height / 2)
          .attr("rx", 8)
          .attr("ry", 8)
          .attr("fill", getStatusColor(d.status))
          .attr("fill-opacity", 0.15)
          .attr("stroke", getStatusColor(d.status))
          .attr("stroke-width", 2)
      } else if (d.type === "machine") {
        // Circle for machines
        el.append("circle")
          .attr("r", NODE_SIZES.machine.radius)
          .attr("fill", getStatusColor(d.status))
          .attr("fill-opacity", 0.2)
          .attr("stroke", getStatusColor(d.status))
          .attr("stroke-width", 2)
      } else if (d.type === "volume") {
        // Small cylinder-like rect for volumes
        el.append("rect")
          .attr("width", NODE_SIZES.volume.width)
          .attr("height", NODE_SIZES.volume.height)
          .attr("x", -NODE_SIZES.volume.width / 2)
          .attr("y", -NODE_SIZES.volume.height / 2)
          .attr("rx", 3)
          .attr("fill", getStatusColor(d.status))
          .attr("fill-opacity", 0.2)
          .attr("stroke", getStatusColor(d.status))
          .attr("stroke-width", 1.5)
      }

      // Label
      el.append("text")
        .text(d.label.length > 14 ? d.label.slice(0, 12) + "…" : d.label)
        .attr("text-anchor", "middle")
        .attr("dy", d.type === "volume" ? NODE_SIZES.volume.height / 2 + 12 : 4)
        .attr("font-size", d.type === "app" ? 11 : 9)
        .attr("font-weight", d.type === "app" ? 600 : 400)
        .attr("fill", "currentColor")
        .attr("class", "text-base-content")

      // Provider badge
      if (d.provider && d.type === "app") {
        el.append("text")
          .text(d.provider.toUpperCase())
          .attr("text-anchor", "middle")
          .attr("dy", -NODE_SIZES.app.height / 2 - 4)
          .attr("font-size", 8)
          .attr("fill", "currentColor")
          .attr("opacity", 0.5)
      }
    })

    // Tooltip
    const tooltip = d3.select(container)
      .append("div")
      .attr("class", "absolute hidden bg-base-300 text-base-content text-xs rounded-lg px-3 py-2 shadow-lg pointer-events-none z-10")

    node.on("mouseover", (event, d) => {
      const lines = [`<strong>${d.label}</strong>`]
      lines.push(`Type: ${d.type}`)
      lines.push(`Status: ${d.status}`)
      if (d.region) lines.push(`Region: ${d.region}`)
      if (d.provider) lines.push(`Provider: ${d.provider}`)

      tooltip.html(lines.join("<br>"))
        .style("left", (event.offsetX + 12) + "px")
        .style("top", (event.offsetY - 12) + "px")
        .classed("hidden", false)
    })
    .on("mouseout", () => tooltip.classed("hidden", true))

    // Click to navigate
    node.on("click", (_event, d) => {
      if (d.navigate_to) {
        this.pushEvent("navigate", { path: d.navigate_to })
      }
    })

    // Region hulls
    const hullGroup = g.insert("g", ".links").attr("class", "hulls")

    // Force simulation
    this.simulation = d3.forceSimulation(this.graphData.nodes)
      .force("link", d3.forceLink(this.graphData.links).id(d => d.id).distance(d => {
        if (d.type === "contains") return 80
        return 60
      }))
      .force("charge", d3.forceManyBody().strength(-200))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(d => {
        if (d.type === "app") return 70
        if (d.type === "machine") return 30
        return 20
      }))
      .on("tick", () => {
        link
          .attr("x1", d => d.source.x)
          .attr("y1", d => d.source.y)
          .attr("x2", d => d.target.x)
          .attr("y2", d => d.target.y)

        node.attr("transform", d => `translate(${d.x},${d.y})`)

        // Update region hulls
        hullGroup.selectAll("path").remove()
        Object.entries(regions).forEach(([region, nodes]) => {
          if (nodes.length < 3) return
          const points = nodes.map(n => [n.x, n.y])
          const hull = d3.polygonHull(points)
          if (hull) {
            const padding = 30
            hullGroup.append("path")
              .attr("d", `M${hull.map(p => p.join(",")).join("L")}Z`)
              .attr("fill", "oklch(0.6 0.05 250)")
              .attr("fill-opacity", 0.05)
              .attr("stroke", "oklch(0.6 0.05 250)")
              .attr("stroke-opacity", 0.15)
              .attr("stroke-width", 1)
          }
        })
      })
  },

  applyUpdate(changes) {
    if (changes.nodes_added) {
      this.graphData.nodes.push(...changes.nodes_added)
    }
    if (changes.nodes_removed) {
      const removeIds = new Set(changes.nodes_removed)
      this.graphData.nodes = this.graphData.nodes.filter(n => !removeIds.has(n.id))
      this.graphData.links = this.graphData.links.filter(l =>
        !removeIds.has(l.source.id || l.source) && !removeIds.has(l.target.id || l.target)
      )
    }
    if (changes.nodes_updated) {
      changes.nodes_updated.forEach(update => {
        const node = this.graphData.nodes.find(n => n.id === update.id)
        if (node) Object.assign(node, update)
      })
    }
    if (changes.links_added) {
      this.graphData.links.push(...changes.links_added)
    }

    this.render()
  }
}

export { TopologyHook }
