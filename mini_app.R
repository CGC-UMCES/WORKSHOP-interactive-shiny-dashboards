# ==============================================================================
#
#  MINI APP - Water Quality Explorer
#  Baltimore Harbor / Chesapeake Bay Region
#
#  A minimal R Shiny app to introduce the core concepts before the full demo.
#  This app has exactly three moving parts:
#
#    1. ONE INPUT    - a dropdown to pick the water quality parameter  (Step 4)
#    2. ONE EVENT    - clicking a station marker on the map            (Step 5.4)
#    3. ONE OUTPUT   - a time series plot that responds to both        (Step 5.5)
#
#  STRUCTURE:
#    Steps 1-3  — setup: packages, data, lookup tables
#    Step 4     — UI: layout, inputs, output placeholders
#    Step 5     — Server function (contains all reactive logic)
#      Step 5.1   reactive value: stores the clicked station
#      Step 5.2   reactive expression: filters data for selected station
#      Step 5.3   renderLeaflet: draws the base map once
#      Step 5.4   observeEvent: handles map marker clicks
#      Step 5.5   renderPlotly: draws the time series
#    Step 6     — launch the app
#
#  Read through each STEP in order. The whole app is ~150 lines.
#
# ==============================================================================


# ==============================================================================
# STEP 1 - LOAD PACKAGES
# ------------------------------------------------------------------------------
# These give R its superpowers: a web app framework, an interactive map,
# an interactive plot, and tools for reading and wrangling data.
# ==============================================================================

library(shiny)      # The reactive web-app framework
library(leaflet)    # Interactive maps
library(plotly)     # Interactive plots
library(dplyr)      # Data manipulation
library(readr)      # Read CSV files


# ==============================================================================
# STEP 2 - LOAD DATA  (runs once at startup, shared across all users)
# ------------------------------------------------------------------------------
# Data is loaded OUTSIDE the server function so it is read into memory once
# and reused. Loading inside server() would re-read the file on every click.
# ==============================================================================

wq <- read_csv("data/wq_baltimore.csv") |>
  mutate(date = as.Date(date))

stations <- wq |>
  distinct(station_id, station_name, lat, lon)


# ==============================================================================
# STEP 3 - LOOKUP TABLES
# ------------------------------------------------------------------------------
# Named vectors: the NAME is what the user sees, the VALUE is used in code.
# This pattern keeps display labels and internal codes in one place.
# ==============================================================================

param_choices <- c(
  "Dissolved Oxygen (mg/L)"   = "dissolved_oxygen",
  "Water Temperature (deg C)" = "temperature",
  "Salinity (ppt)"            = "salinity",
  "Chlorophyll-a (ug/L)"      = "chlorophyll_a"
)

param_units <- c(
  dissolved_oxygen = "mg/L",
  temperature      = "deg C",
  salinity         = "ppt",
  chlorophyll_a    = "ug/L"
)


# ==============================================================================
# STEP 4 - USER INTERFACE (UI)
# ------------------------------------------------------------------------------
# The UI is a DESCRIPTION of the layout — no data, no logic, no computation.
# It creates two things:
#   INPUT  widgets  — controls the user can change  (the dropdown)
#   OUTPUT placeholders — empty boxes the server fills in reactively
#
# Notice the inputId and outputId strings — these are the "wires" that
# connect the UI to the server:
#   input$variable    <- server reads the dropdown value through this
#   output$map        <- server writes the rendered map to this
#   output$ts_plot    <- server writes the rendered plot to this
# ==============================================================================

ui <- fluidPage(

  titlePanel("Chesapeake Bay Water Quality Explorer"),

  sidebarLayout(

    # -- Sidebar: INPUT controls -----------------------------------------------
    sidebarPanel(
      width = 3,

      h4("Select a parameter"),

      # INPUT: selectInput() — a dropdown menu
      # inputId = "variable" means the server reads it as input$variable
      selectInput(
        inputId  = "variable",
        label    = "Water quality parameter",
        choices  = param_choices,
        selected = "dissolved_oxygen"
      ),

      hr(),
      p("Click a station marker on the map to see its time series.",
        style = "color: #888; font-size: 12px;")
    ),

    # -- Main panel: OUTPUT placeholders ---------------------------------------
    mainPanel(
      width = 9,

      # OUTPUT: leafletOutput() — empty box, server fills it via output$map
      leafletOutput("map", height = "350px"),

      br(),

      # OUTPUT: plotlyOutput() — empty box, server fills it via output$ts_plot
      plotlyOutput("ts_plot", height = "280px")
    )
  )
)


# ==============================================================================
# STEP 5 - SERVER
# ------------------------------------------------------------------------------
# The server is a FUNCTION that runs once per user session.
# Everything inside it participates in Shiny's reactive graph:
# when an input changes, only the outputs that depend on it re-run.
# ==============================================================================

server <- function(input, output, session) {

  # ============================================================================
  # STEP 5.1 - REACTIVE VALUE  (shared mutable state)
  # ----------------------------------------------------------------------------
  # reactiveValues() holds state that is SET by events (map clicks) rather
  # than input widgets. When it changes, everything that reads it re-runs.
  # ============================================================================

  rv <- reactiveValues(
    selected_station = NULL    # station_id of the clicked marker; NULL = none
  )


  # ============================================================================
  # STEP 5.2 - REACTIVE EXPRESSION  (computes and returns a value)
  # ----------------------------------------------------------------------------
  # reactive({ }) is for COMPUTING things. It returns a value that other
  # parts of the app can use. Think of it as a smart variable that knows
  # when to update itself.
  #
  # Key properties:
  #   Lazy   — only runs when something downstream asks for the result
  #   Cached — stores the result; if inputs haven't changed, the next
  #            caller gets the cached value instantly (no recomputation)
  #
  # This reactive expression reads TWO inputs:
  #   input$variable       — the parameter dropdown (Step 4)
  #   rv$selected_station  — the clicked station (Step 5.1)
  #
  # When EITHER changes, the cache clears and the plot in Step 5.5
  # automatically re-renders next time it asks for the value.
  #
  # NOTE: changing the dropdown does NOT directly trigger any observer —
  # it simply invalidates this reactive expression's cache, which
  # propagates downstream to renderPlotly() in Step 5.5.
  # ============================================================================

  wq_station <- reactive({
    req(rv$selected_station)          # stop silently if nothing is selected yet
    wq |>
      filter(
        station_id == rv$selected_station,
        parameter  == input$variable
      ) |>
      arrange(date)
  })

  # Per-station mean for the current parameter — drives marker colours
  # Re-runs when input$variable changes, immediately recoloring all markers
  station_means <- reactive({
    wq |>
      filter(parameter == input$variable) |>
      group_by(station_id) |>
      summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop") |>
      left_join(stations, by = "station_id")
  })


  # ============================================================================
  # STEP 5.3 - BASE MAP  (renderLeaflet)
  # ----------------------------------------------------------------------------
  # renderLeaflet() runs ONCE at startup to draw the empty base map.
  # All marker updates happen via leafletProxy() in Steps 5.4 and 5.4b
  # so the map never redraws from scratch when inputs change.
  # ============================================================================

  output$map <- renderLeaflet({
    leaflet() |>
      addProviderTiles(providers$CartoDB.Positron) |>
      setView(lng = -76.50, lat = 39.25, zoom = 9)
  })

  # -- Step 5.4b: Update marker colours when parameter changes ----------------
  # observe() re-runs whenever station_means() changes (i.e. when the dropdown
  # changes). It recolors all markers using leafletProxy() — no map redraw.
  observe({
    df  <- station_means()
    pal <- colorNumeric("YlOrRd", domain = df$mean_val)

    leafletProxy("map") |>
      clearGroup("WQ Stations") |>
      addCircleMarkers(
        data        = df,
        lng         = ~lon,
        lat         = ~lat,
        group       = "WQ Stations",
        layerId     = ~station_id,
        radius      = 7,
        fillColor   = ~pal(mean_val),
        fillOpacity = 0.9,
        color       = "#333",
        weight      = 1,
        label       = ~paste0(station_name, ": ", round(mean_val, 2),
                              " ", param_units[input$variable])
      ) |>
      addLegend(
        position = "bottomright",
        pal      = colorNumeric("YlOrRd", domain = df$mean_val, reverse = TRUE),
        values   = df$mean_val,
        title    = paste0("Mean<br>", param_units[input$variable]),
        layerId  = "legend",
        labFormat = labelFormat(transform = function(x) sort(x, decreasing = TRUE))
      )
  })


  # ============================================================================
  # STEP 5.4 - OBSERVER  (does something, returns nothing)
  # ----------------------------------------------------------------------------
  # observeEvent() is for DOING things. Unlike reactive(), it has no return
  # value — it exists purely to cause SIDE EFFECTS when its trigger fires.
  #
  # The difference in one line:
  #   reactive()      = "compute this value whenever inputs change"
  #   observeEvent()  = "do this action whenever the trigger fires"
  #
  # Here the trigger is input$map_marker_click — it fires when the user
  # clicks a station marker. The side effects are:
  #   1. Write the clicked station id to rv$selected_station
  #      -> this invalidates wq_station() (Step 5.2)
  #      -> which causes ts_plot (Step 5.5) to re-render
  #   2. Add a yellow highlight ring to the map via leafletProxy()
  #
  # This is the core reactive LINKAGE:
  #   map click -> rv$selected_station changes -> wq_station() recomputes
  #             -> ts_plot re-renders
  # ============================================================================

  observeEvent(input$map_marker_click, {
    click <- input$map_marker_click
    if (!is.null(click$id)) {
      rv$selected_station <- click$id

      # Add a yellow highlight ring around the selected marker
      leafletProxy("map") |>
        clearGroup("selected") |>
        addCircleMarkers(
          data        = stations |> filter(station_id == click$id),
          lng         = ~lon,
          lat         = ~lat,
          group       = "selected",
          radius      = 13,
          fillColor   = "transparent",
          fillOpacity = 0,
          color       = "#FFD700",
          weight      = 3
        )
    }
  })


  # ============================================================================
  # STEP 5.5 - RENDER FUNCTION  (output that re-runs when its inputs change)
  # ----------------------------------------------------------------------------
  # renderPlotly() re-runs whenever wq_station() changes — which happens when:
  #   1. The user clicks a different station marker  (via rv$selected_station)
  #   2. The user changes the parameter dropdown     (via input$variable)
  #
  # renderPlotly() is neither a reactive nor an observer — it is a RENDER
  # FUNCTION. It works like a reactive (lazy, cached, re-runs on invalidation)
  # but its job is specifically to produce output for the UI.
  #
  # The reactive chain for a dropdown change looks like this:
  #   input$variable changes
  #     -> wq_station() cache invalidated  (Step 5.2 reads input$variable)
  #       -> renderPlotly() re-runs        (Step 5.5 reads wq_station())
  #         -> plot updates in the browser
  #
  # Two user actions, one plot, zero manual wiring. That is reactive programming.
  # ============================================================================

  output$ts_plot <- renderPlotly({

    # Show a prompt until a station is selected
    if (is.null(rv$selected_station)) {
      return(plotly_empty() |>
        layout(title = list(
          text = "Click a station marker on the map to see its time series",
          font = list(size = 14, color = "#888")
        )))
    }

    df       <- wq_station()
    st_name  <- stations$station_name[stations$station_id == rv$selected_station]
    units    <- param_units[input$variable]

    plot_ly(
      df,
      x             = ~date,
      y             = ~value,
      type          = "scatter",
      mode          = "lines+markers",
      line          = list(color = "#1a6ebd", width = 2),
      marker        = list(color = "#1a6ebd", size  = 4),
      hovertemplate = "%{x|%Y-%m}: %{y:.2f}<extra></extra>"
    ) |>
      layout(
        title  = list(text = paste0(st_name, " — ", names(param_choices)[param_choices == input$variable]),
                      font = list(size = 14)),
        xaxis  = list(title = ""),
        yaxis  = list(title = units),
        margin = list(t = 40)
      ) |>
      config(modeBarButtonsToRemove = list("select2d", "lasso2d"))
  })

}


# ==============================================================================
# STEP 6 - LAUNCH THE APP
# ==============================================================================

shinyApp(ui = ui, server = server)
