# ==============================================================================
#
#  WORKSHOP DEMO: Interactive Environmental Dashboard
#  Baltimore Harbor / Chesapeake Bay Region
#
#  R Shiny + RStudio Hands-On Tutorial
#  Estimated walk-through time: ~45 minutes
#
#  HOW TO USE THIS FILE
#  --------------------
#  This script is divided into numbered STEPS. Each step has:
#    [CONCEPT]  - the Shiny idea being introduced
#    [WHY]      - why it matters / what it enables in the app
#    [DO]       - what to run or observe at this point in the tutorial
#
#  Work through the steps in order. The app is runnable from Step 9 onward
#  (the simulated data in Step 3 always provides a working fallback).
#
#  DATA LAYERS (swap in real files at Step 2):
#    - CBP Water Quality time series  (CSV)   - Baltimore Harbor stations
#    - HUC8 Watershed Polygons        (sf)    - Chesapeake Bay region
#    - NLCD Land Cover Raster         (terra) - 30 m, clipped to region
#    - USGS Stream Gauge Points       (sf)    - point layer
#
#  REACTIVE LINKAGES (the heart of this demo):
#    - Click a watershed polygon  -> clips raster + filters WQ + updates table
#    - Click a WQ station marker  -> shows that station's time series
#    - Move the date range slider -> updates time series + summary table
#    - Change variable dropdown   -> switches parameter in ALL panels at once
#
#  SHARING YOUR APP (see Step 17 at the bottom for full details)
#  -------------------------------------------------------------
#  Option A - shinyapps.io (recommended, free, permanent URL):
#    rsconnect::deployApp()
#
#  Option B - ngrok (temporary public tunnel, no deployment needed):
#    ngrok does not care what language or framework your app uses - it just
#    tunnels whatever is running on a local port to a public URL. Works
#    identically for Shiny, Streamlit, Flask, FastAPI, Dash, etc.
#    1. Start the app in RStudio, check the port in the browser URL
#    2. In a terminal: ngrok http PORT_NUMBER
#    3. Share the https://xxxx.ngrok-free.app forwarding URL
#    Note: free tier URL changes each session, tunnel closes when terminal closes
#
# ==============================================================================


# ==============================================================================
# STEP 1 - LOAD PACKAGES
# ------------------------------------------------------------------------------
# [CONCEPT] Every Shiny app starts by loading its dependencies.
#           Each package adds a specific capability to our app.
#
# [WHY]     Without these, R has no map widget, no interactive plots,
#           no spatial operations, and no reactive framework.
#
# [DO]      Run just this block first (select all lines and Ctrl+Enter).
#           Watch the console - any red "Error" here means a package is
#           missing. Install everything needed for this app in one shot:
#
#             install.packages(c(
#               "shiny", "shinydashboard", "leaflet",
#               "sf", "terra", "dplyr", "tidyr", "readr",
#               "plotly", "DT", "zoo"
#             ))
#
#           NOTE: leaflet.extras (adds a freehand draw toolbar to the map)
#           has been removed from this app. The package installs without issue
#           but integrating it requires non-trivial code changes beyond simply
#           adding the library and a single function call. If you wish to attempt it:
#             install.packages("leaflet.extras")
#           Add library(leaflet.extras) below and addDrawToolbar() in the
#           renderLeaflet block in Step 9, then expect additional debugging.
# ==============================================================================

library(shiny)           # The reactive web-app framework - the engine of everything
library(shinydashboard)  # Gives us the sidebar + box layout used in this app
library(leaflet)         # Interactive maps (pan, zoom, click events)
library(raster)          # Required for addRasterImage - load BEFORE dplyr so dplyr::select wins
library(sf)              # Vector spatial data: points, lines, polygons
library(terra)           # Raster spatial data: grids, pixel values, extraction
library(dplyr)           # Data manipulation: filter, group_by, summarise, etc.
# Explicitly restore dplyr::select after raster masks it
select <- dplyr::select
library(tidyr)           # Reshaping data: pivot_longer, expand_grid, etc.
library(readr)           # Fast CSV reading with read_csv()
library(plotly)          # Interactive plots with hover, zoom, and pan
library(DT)              # Interactive sortable data tables in Shiny
library(zoo)             # Rolling/moving averages for the time series smoother


# ==============================================================================
# STEP 2 - LOAD REAL DATA  (commented out until you have the files)
# ------------------------------------------------------------------------------
# [CONCEPT] Data is loaded ONCE at startup, OUTSIDE the server function.
#           This means it is read into memory once and shared across all
#           user sessions - keeping the app fast.
#
# [WHY]     If you put read_csv() inside server(), the file is re-read every
#           time any reactive expression updates. That is very slow.
#           Loading outside server() = load once, reuse forever.
#
# [DO]      When you have real data files, un-comment the lines below and
#           update the file paths. Then comment out the entire STEP 3 block.
#           No other changes are needed - the rest of the app is data-agnostic
#           as long as the column names match those described below.
# ==============================================================================

# -- Water quality time series (CSV) -----------------------------------------
# Downloaded and prepared by data_prep.R
# Columns: station_id, station_name, lat, lon, date, parameter, value
#
wq <- read_csv("data/wq_baltimore.csv") |>
  mutate(date = as.Date(date))

# Extract station metadata from the water quality data
# (coordinates and names are embedded in the CSV)
stations <- wq |>
  distinct(station_id, station_name, lat, lon)

# -- Watershed polygons (GeoPackage) ------------------------------------------
# Downloaded and simplified by data_prep.R from USGS NHD via nhdplusTools
#
watersheds <- st_read("data/watersheds_baltimore.gpkg", quiet = TRUE) |>
  st_transform(4326)

# -- NLCD Land Cover Raster ---------------------------------------------------
# Downloaded and resampled to 90m by data_prep.R from MRLC via FedData
#
nlcd <- rast("data/nlcd_baltimore.tif")

# Pre-convert to raster package format and build palette once at startup
# This avoids re-doing the conversion every time the layer is toggled
nlcd_raster <- raster::raster(nlcd)
nlcd_pal    <- colorFactor(
  palette  = c("#5475A8","#E8D1D1","#E29E8C","#FF0000","#B50000","#D2CDC0",
               "#85C77E","#38814E","#D4E7B0","#DCCA8F","#FDE9AA","#FBF65D",
               "#CA9146","#C8E6F8","#64B3D5"),
  levels   = c(11,21,22,23,24,31,41,42,43,52,71,81,82,90,95),
  na.color = "transparent"
)


# ==============================================================================
# STEP 3 - SIMULATED DATA  (stand-in until real files are ready)
# ------------------------------------------------------------------------------
# [CONCEPT] Synthetic placeholder data lets you build and test the full app
#           interface and reactive logic before real datasets exist.
#           This is standard professional practice.
#
# [WHY]     The app is structure-driven. As long as column names and data
#           types match what the server expects, real data can drop in with
#           zero code changes elsewhere.
#
# [DO]      Read through this block to understand the expected data structure.
#           Notice set.seed(42): this makes random numbers reproducible -
#           every run produces the same simulated values.
#           DELETE or comment out this entire block once real data is loaded.
#
#           NOTE: This block is commented out because real data has been loaded
#           in Step 2. To revert to simulated data, un-comment this block and
#           comment out the Step 2 loading block above.
# ==============================================================================
if (FALSE) {  # Set to TRUE to use simulated data instead of real data

set.seed(42)   # Reproducible random simulation

# -- Station metadata (8 Baltimore Harbor / Chesapeake monitoring stations) ---
stations <- tibble(
  station_id   = paste0("CBP-", 1:8),
  station_name = c("Inner Harbor", "Middle Branch", "Back River",
                   "Patapsco River", "Bear Creek", "Rock Creek",
                   "Magothy River",  "Severn River"),
  lat = c(39.285, 39.270, 39.310, 39.255, 39.225, 39.360, 39.105, 39.010),
  lon = c(-76.612,-76.628,-76.525,-76.660,-76.480,-76.590,-76.530,-76.488)
)

# -- Water quality time series ------------------------------------------------
# expand_grid() creates every combination of station x date x parameter.
# We simulate realistic values for each parameter:
#   temperature: sine wave to mimic seasonal variation
#   others: normally distributed with realistic means and SDs
wq <- expand_grid(
  station_id = stations$station_id,
  date       = seq(as.Date("2015-01-01"), as.Date("2023-12-31"), by = "month"),
  parameter  = c("dissolved_oxygen", "temperature", "salinity", "chlorophyll_a")
) |>
  left_join(stations, by = "station_id") |>
  mutate(
    value = case_when(
      parameter == "dissolved_oxygen" ~ rnorm(n(), 7.5, 1.5),
      parameter == "temperature"      ~ 15 + 12 * sin(
                                          (as.numeric(format(date, "%m")) - 3) * pi / 6
                                        ) + rnorm(n(), 0, 1.5),
      parameter == "salinity"         ~ rnorm(n(), 8, 2),
      parameter == "chlorophyll_a"    ~ abs(rnorm(n(), 12, 6))
    ),
    value = round(value, 2)
  )

# -- Watershed polygons (simplified but realistic shapes) ---------------------
# These polygons approximate the actual HUC8 watershed boundaries for the
# Baltimore / upper Chesapeake Bay region, hand-digitised from USGS NHD
# reference maps. They are simplified (fewer vertices than real boundaries)
# but capture the general shape and orientation of each watershed.
# st_polygon() builds a polygon from a coordinate matrix — the first and
# last row must be identical to close the ring.
make_poly_sf <- function(coords, name, huc, area) {
  st_sf(
    huc8_name = name,
    huc8      = huc,
    area_km2  = area,
    geometry  = st_sfc(
      st_polygon(list(matrix(coords, ncol = 2, byrow = TRUE))),
      crs = 4326
    )
  )
}

watersheds <- bind_rows(

  # Patapsco River watershed - drains northwest into Baltimore Harbor
  # Elongated NW-SE shape following the river corridor
  make_poly_sf(c(
    -76.88, 39.42,
    -76.75, 39.48,
    -76.60, 39.45,
    -76.52, 39.38,
    -76.48, 39.28,
    -76.55, 39.22,
    -76.65, 39.20,
    -76.72, 39.24,
    -76.80, 39.30,
    -76.85, 39.36,
    -76.88, 39.42
  ), "Patapsco", "02060003", 1554),

  # Back River watershed - smaller, east of Baltimore
  # Compact roughly triangular shape draining east into Back River
  make_poly_sf(c(
    -76.55, 39.38,
    -76.48, 39.42,
    -76.38, 39.40,
    -76.32, 39.32,
    -76.35, 39.24,
    -76.45, 39.20,
    -76.52, 39.22,
    -76.55, 39.30,
    -76.55, 39.38
  ), "Back River", "02060002", 388),

  # Severn River watershed - south of Baltimore, drains into the Bay
  # Wider southern shape following the Severn River corridor
  make_poly_sf(c(
    -76.72, 39.24,
    -76.65, 39.20,
    -76.58, 39.16,
    -76.52, 39.08,
    -76.48, 39.00,
    -76.55, 38.96,
    -76.65, 38.97,
    -76.75, 39.02,
    -76.80, 39.10,
    -76.78, 39.18,
    -76.72, 39.24
  ), "Severn River", "02060004", 622),

  # Gunpowder / Bush watershed - north and east of Baltimore
  # Broader shape draining northeast into the upper Bay
  make_poly_sf(c(
    -76.48, 39.42,
    -76.38, 39.48,
    -76.25, 39.50,
    -76.18, 39.42,
    -76.20, 39.32,
    -76.28, 39.24,
    -76.35, 39.24,
    -76.38, 39.32,
    -76.42, 39.38,
    -76.48, 39.42
  ), "Gunpowder-Bush", "02060001", 1432)
)

# -- NLCD-style raster --------------------------------------------------------
# Rather than assigning classes randomly, we simulate a spatially coherent
# landscape using distance from the Inner Harbor as the driving gradient.
# Close to the harbor = heavily developed; moving outward = progressively more
# forest, wetlands, and open water along the Bay shoreline.
#
# terra uses SpatRaster objects - different from the older 'raster' package.
# terra is significantly faster and handles large files more efficiently.
nlcd_classes <- c(11, 21, 22, 23, 24, 31, 41, 42, 43, 52, 71, 81, 82, 90, 95)
nlcd_labels  <- c("Open Water","Developed Open","Developed Low","Developed Med",
                  "Developed High","Barren","Deciduous Forest","Evergreen Forest",
                  "Mixed Forest","Shrub/Scrub","Grassland","Pasture",
                  "Cultivated Crops","Woody Wetlands","Emergent Wetlands")
nlcd_colors  <- c("#5475A8","#E8D1D1","#E29E8C","#FF0000","#B50000","#D2CDC0",
                  "#85C77E","#38814E","#D4E7B0","#DCCA8F","#FDE9AA","#FBF65D",
                  "#CA9146","#C8E6F8","#64B3D5")

# Create empty raster grid covering the Baltimore / upper Bay region
r <- rast(
  nrows = 100, ncols = 100,
  xmin = -76.75, xmax = -76.30,
  ymin =  38.95, ymax =  39.40,
  crs  = "EPSG:4326"
)

# Compute each pixel's distance from Inner Harbor (lat 39.285, lon -76.612)
# xFromCell / yFromCell extract pixel centre coordinates as vectors
harbor_lon <- -76.612
harbor_lat <-  39.285
px_lon <- xFromCell(r, 1:ncell(r))
px_lat <- yFromCell(r, 1:ncell(r))

# Euclidean distance in degree-space (good enough for a simulation at this scale)
dist_from_harbor <- sqrt((px_lon - harbor_lon)^2 + (px_lat - harbor_lat)^2)

# Normalise to 0-1 so we can use it to blend probability vectors
dist_norm <- (dist_from_harbor - min(dist_from_harbor)) /
             (max(dist_from_harbor) - min(dist_from_harbor))

# Also flag pixels near the Bay shoreline (south/east edge) for water + wetlands
near_water <- (px_lat < 39.10) | (px_lon > -76.40)

# Probability vectors for three zones:
#   urban core  - dominated by developed classes
#   suburbs     - mix of developed, forest, pasture
#   rural/fringe- forest, wetlands, open water
prob_urban  <- c(.05,.06,.12,.15,.14,.02,.10,.04,.03,.02,.02,.05,.03,.08,.09)
prob_suburb <- c(.04,.12,.14,.10,.05,.02,.16,.08,.06,.04,.04,.08,.04,.02,.01)
prob_rural  <- c(.12,.06,.05,.02,.01,.01,.22,.12,.08,.05,.05,.07,.04,.06,.04)

# Blend probabilities per pixel based on distance from harbor
# near_water pixels get extra weight on open water + wetland classes
pixel_classes <- vapply(seq_len(ncell(r)), function(i) {
  if (near_water[i]) {
    probs <- c(.25,.03,.02,.01,.01,.01,.08,.04,.03,.02,.02,.02,.01,.20,.25)
  } else {
    w <- dist_norm[i]   # 0 = at harbor, 1 = far edge
    probs <- (1 - w) * prob_urban + w * ifelse(w > 0.5, prob_rural, prob_suburb)
  }
  # Add small spatial noise so adjacent pixels aren't perfectly identical
  probs <- probs + runif(length(probs), 0, 0.02)
  probs <- probs / sum(probs)   # re-normalise after adding noise
  sample(nlcd_classes, 1, prob = probs)
}, double(1))

values(r) <- as.integer(pixel_classes)
names(r)  <- "landcover"
nlcd <- r    # alias - replace with rast("data/nlcd_chesapeake.tif") for real data

}  # end if (FALSE) - simulated data block
# ---- END SIMULATED DATA BLOCK -----------------------------------------------


# ==============================================================================
# STEP 4 - LOOKUP TABLES AND HELPER OBJECTS
# ------------------------------------------------------------------------------
# [CONCEPT] Small, reusable objects created once at the top of the script.
#           Used throughout the UI and server to avoid hardcoding the same
#           strings in multiple places (DRY - Don't Repeat Yourself).
#
# [WHY]     If you hardcoded "dissolved_oxygen" and "mg/L" in ten different
#           places, adding a new parameter would require ten edits - and one
#           missed spot would silently break the app. Centralised lookups mean
#           one change propagates everywhere automatically.
#
# [DO]      Notice how param_choices uses a NAMED vector:
#             "Dissolved Oxygen (mg/L)" = "dissolved_oxygen"
#           The NAME is what the user sees in the dropdown.
#           The VALUE is the internal code the server uses for filtering.
#           This pattern appears throughout Shiny UI input definitions.
# ==============================================================================

# Named vector: human-readable label -> internal column value used in filtering
param_choices <- c(
  "Dissolved Oxygen (mg/L)" = "dissolved_oxygen",
  "Water Temperature (deg C)" = "temperature",
  "Salinity (ppt)"          = "salinity",
  "Chlorophyll-a (ug/L)"   = "chlorophyll_a"
)

# Units per parameter: used for axis labels, popups, and legend titles
param_units <- c(
  dissolved_oxygen = "mg/L",
  temperature      = "deg C",
  salinity         = "ppt",
  chlorophyll_a    = "ug/L"
)

# NLCD class lookup table: integer code -> display label + standard hex colour
# These are the standard NLCD class codes, labels, and colours used by the
# MRLC. They apply to both the real and simulated NLCD rasters.
nlcd_classes <- c(11, 21, 22, 23, 24, 31, 41, 42, 43, 52, 71, 81, 82, 90, 95)
nlcd_labels  <- c("Open Water","Developed Open","Developed Low","Developed Med",
                  "Developed High","Barren","Deciduous Forest","Evergreen Forest",
                  "Mixed Forest","Shrub/Scrub","Grassland","Pasture",
                  "Cultivated Crops","Woody Wetlands","Emergent Wetlands")
nlcd_colors  <- c("#5475A8","#E8D1D1","#E29E8C","#FF0000","#B50000","#D2CDC0",
                  "#85C77E","#38814E","#D4E7B0","#DCCA8F","#FDE9AA","#FBF65D",
                  "#CA9146","#C8E6F8","#64B3D5")

nlcd_lookup <- tibble(
  value = nlcd_classes,
  label = nlcd_labels,
  color = nlcd_colors
)


# ==============================================================================
# STEP 5 - THE USER INTERFACE (UI)
# ------------------------------------------------------------------------------
# [CONCEPT] The UI is a DESCRIPTION of the layout. It tells the browser what
#           to render. It contains no data, no logic, and no computations.
#           The UI is evaluated once when the app starts.
#
# [WHY]     Separating layout (UI) from logic (server) is the core design
#           principle of Shiny. The UI creates:
#             INPUT widgets  - controls the user can change (dropdowns, sliders)
#             OUTPUT placeholders - blank boxes the server fills in reactively
#
# [DO]      Read the structure top-to-bottom before looking at the server.
#           Identify every inputId and every outputId - these are the "wires"
#           connecting UI to server:
#             input$<inputId>   <- the server reads user selections through these
#             output$<outputId> <- the server writes rendered results to these
#
#           Overall layout:
#             dashboardPage()
#               +- dashboardHeader()     <- title bar
#               +- dashboardSidebar()    <- all INPUT controls
#               +- dashboardBody()
#                     +- fluidRow()      <- Row 1: map (left) + land cover (right)
#                     +- fluidRow()      <- Row 2: time series (left) + table (right)
# ==============================================================================

ui <- dashboardPage(
  skin = "blue",

  # ----------------------------------------------------------------------------
  # 5a. HEADER
  # ----------------------------------------------------------------------------
  dashboardHeader(title = "Chesapeake Bay Environmental Dashboard"),

  # ----------------------------------------------------------------------------
  # 5b. SIDEBAR - all INPUT controls live here
  # [CONCEPT] Each input widget has an inputId. The server accesses the current
  #           value of that widget using input$<inputId>. When the user changes
  #           any input, Shiny automatically re-runs all downstream code that
  #           reads that input - no manual update triggers needed.
  # ----------------------------------------------------------------------------
  dashboardSidebar(

    # INPUT: selectInput() - dropdown menu
    # inputId = "variable" -> server reads it as input$variable
    # choices uses param_choices: the name is shown, the value is used in code
    selectInput(
      inputId  = "variable",
      label    = "Water Quality Parameter",
      choices  = param_choices,
      selected = "dissolved_oxygen"
    ),

    # INPUT: sliderInput() with two handles (date range)
    # Returns a vector of two dates: input$date_range[1] and input$date_range[2]
    # timeFormat = "%Y-%m" controls how the date appears on the slider labels
    sliderInput(
      inputId    = "date_range",
      label      = "Date Range",
      min        = min(wq$date),
      max        = max(wq$date),
      value      = c(min(wq$date), max(wq$date)),
      timeFormat = "%Y-%m",
      step       = 30    # step in days
    ),

    hr(),
    h5("Map layers", style = "padding-left:15px; color:#aaa"),

    # INPUT: checkboxInput() - TRUE/FALSE toggles
    # Each one controls an observe() block in the server that adds/removes
    # a specific layer from the Leaflet map.
    # Order matches the visual stacking - top of list = top of map.
    checkboxInput("show_stations",   "WQ stations",        value = TRUE),
    checkboxInput("show_watersheds", "Watershed polygons", value = TRUE),
    checkboxInput("show_nlcd",       "NLCD land cover",    value = FALSE),

    # NLCD colour legend - only shown when the NLCD layer is active
    conditionalPanel(
      condition = "input.show_nlcd == true",
      hr(),
      h5("NLCD land cover classes",
         style = "padding-left:15px; color:#aaa; margin-bottom:6px"),
      div(
        style = "padding: 0 15px; font-size: 11px; line-height: 2",
        lapply(seq_len(nrow(nlcd_lookup)), function(i) {
          div(
            style = "display:flex; align-items:center; gap:6px",
            div(style = paste0(
              "width:14px; height:14px; border-radius:2px; flex-shrink:0;",
              "background:", nlcd_lookup$color[i], ";"
            )),
            span(nlcd_lookup$label[i])
          )
        })
      )
    ),

    hr(),

    # Static help text - pure HTML, not an input
    div(
      style = "padding:10px 15px; font-size:12px; color:#aaa; line-height:1.8",
      strong("How to interact:"), br(),
      "• Click a watershed to see land cover + stats", br(),
      "• Click a station marker for its time series",  br(),
      "• Click a row in the summary table to select that station", br(),
      "• Adjust date range or parameter above"
    )
  ),

  # ----------------------------------------------------------------------------
  # 5c. BODY - OUTPUT placeholders live here
  # [CONCEPT] Functions like leafletOutput(), plotlyOutput(), DTOutput() are
  #           empty containers. They render as blank boxes until the server
  #           fills them via output$<outputId> <- render*({ ... })
  # [DO]      Count the outputIds here: map, ts_title, ts_plot, dist_title,
  #           dist_plot, summary_table. Find each one in the server below.
  # ----------------------------------------------------------------------------
  dashboardBody(

    # Minor visual polish via CSS (rounded boxes, light grey background)
    tags$head(
      tags$style(HTML("
        .content-wrapper  { background: #f4f4f4; }
        .box               { border-radius: 6px; }
        .leaflet-container { border-radius: 6px; }
        #summary_table table { font-size: 15px; }
        #summary_table .dataTables_wrapper { font-size: 15px; }
      ")),
      # JavaScript to catch basemap changes and send to Shiny
      # input$map_baselayerchange is unreliable on first switch so we
      # use a custom Shiny message handler instead
      tags$script(HTML("
        $(document).on('shiny:connected', function() {
          setTimeout(function() {
            var map = HTMLWidgets.find('#map').getMap();
            map.on('baselayerchange', function(e) {
              Shiny.setInputValue('basemap_changed', e.name, {priority: 'event'});
            });
          }, 1000);
        });
      "))
    ),

    # -- ROW 1: Map + Land Cover (top row) -------------------------------------
    # [CONCEPT] shinydashboard uses Bootstrap's 12-column grid system.
    #           Two boxes at width=6 each fills the full row (6+6=12).
    #           Map and land cover are paired here because both respond to
    #           watershed polygon clicks - clicking a polygon updates both.
    fluidRow(class = "equal-height",

      # Panel A: Interactive map
      box(
        width       = 6,
        title       = tagList(
          icon("map"),
          " Interactive Map - click a watershed polygon or station marker"
        ),
        status      = "primary",
        solidHeader = TRUE,
        class       = "box-top",
        leafletOutput("map", height = "420px")
      ),

      # Panel B: NLCD land cover distribution
      box(
        width       = 6,
        title       = tagList(icon("chart-bar"), " Land Cover Distribution"),
        status      = "success",
        solidHeader = TRUE,
        class       = "box-top",
        uiOutput("dist_title"),
        plotlyOutput("dist_plot", height = "400px")
      )
    ),

    # -- ROW 2: Time series + Summary table (bottom row) ----------------------
    fluidRow(class = "equal-height",

      # Panel C: Time series plot
      box(
        width       = 6,
        title       = tagList(icon("chart-line"), " Time Series"),
        status      = "info",
        solidHeader = TRUE,
        class       = "box-bottom",
        uiOutput("ts_title"),
        plotlyOutput("ts_plot", height = "300px")
      ),

      # Panel D: Summary statistics table
      box(
        width       = 6,
        title       = tagList(icon("table"), " Watershed Summary"),
        status      = "warning",
        solidHeader = TRUE,
        class       = "box-bottom",
        DTOutput("summary_table")
      )
    )
  )
)


# ==============================================================================
# STEP 6 - THE SERVER FUNCTION
# ------------------------------------------------------------------------------
# [CONCEPT] server() is called by Shiny once per user session. It takes three
#           arguments:
#             input   - read-only list of current input widget values
#             output  - write-only list where rendered results are assigned
#             session - metadata about the current browser connection
#
# [WHY]     Everything inside server() participates in Shiny's reactive graph.
#           When an input changes, Shiny traces the dependency graph and
#           automatically re-runs only the expressions that depend on it.
#           You never write update loops or manual refresh logic.
#
# [DO]      As you read each sub-section, ask two questions:
#             "What input(s) or reactive values trigger this?"
#             "What output(s) does this update?"
#           Tracing these dependency chains IS understanding Shiny.
# ==============================================================================

server <- function(input, output, session) {

  # ============================================================================
  # STEP 7 - REACTIVE VALUES  (shared mutable state)
  # ----------------------------------------------------------------------------
  # [CONCEPT] reactiveValues() creates a list that Shiny watches for changes.
  #           When any value inside it is modified, every reactive expression
  #           or render function that READ that value is automatically
  #           invalidated and re-run on its next access.
  #
  # [WHY]     The user's map selections (which watershed, which station) are
  #           not standard input widgets - they come from map click events.
  #           reactiveValues() is the right home for state that is set by
  #           event handlers rather than UI controls.
  #
  # [DO]      Notice both values start as NULL (nothing selected).
  #           They are written to by observeEvent() blocks in Step 11.
  #           They are read by reactive() expressions in Step 8 and
  #           render functions in Steps 12-14, creating the linkages.
  # ============================================================================

  rv <- reactiveValues(
    selected_watershed = NULL,   # huc8 ID of the clicked watershed polygon
    selected_station   = NULL    # station_id of the clicked WQ marker
  )


  # ============================================================================
  # STEP 8 - REACTIVE EXPRESSIONS  (filtered and derived data)
  # ----------------------------------------------------------------------------
  # [CONCEPT] reactive({ }) creates a LAZILY EVALUATED, CACHED computation:
  #
  #   Lazy    - only runs when something downstream asks for the result
  #   Cached  - the result is stored; if inputs haven't changed, subsequent
  #             callers get the cached value instantly (no recomputation)
  #   Auto-invalidating - when any input it reads changes, the cache is
  #             cleared and the next caller triggers a fresh computation
  #
  # [WHY]     Three output panels all need the date-filtered water quality data.
  #           Using reactive() means the filter runs ONCE per input change and
  #           the result is shared. Without it, each panel would re-filter
  #           independently - wasteful and potentially inconsistent.
  #
  # [DO]      Trace the full dependency chain before moving to the render steps:
  #
  #           input$variable  -|
  #           input$date_range ─+-> wq_filtered()
  #                             |         |
  #           rv$selected_station ----+-> wq_station() -> ts_plot
  #                             |         |
  #                             +----─+-> ws_summary() -> summary_table
  #
  #           rv$selected_watershed -> selected_ws()
  #                                          |
  #                                    nlcd_in_ws()     <- terra crop + mask
  #                                          |
  #                                    nlcd_summary()   <- pixel count table
  #                                          |
  #                                    dist_plot        <- bar chart
  # ============================================================================

  # -- 8a. Water quality filtered by current parameter + date window ----------
  # This is the shared base dataset. All downstream WQ expressions call this.
  wq_filtered <- reactive({
    wq |>
      filter(
        parameter == input$variable,       # reads the dropdown: input$variable
        date      >= input$date_range[1],  # reads slider start: input$date_range[1]
        date      <= input$date_range[2]   # reads slider end:   input$date_range[2]
      )
  })

  # -- 8b. Time series for the single selected station -----------------------
  # req() is a guard clause: if selected_station is NULL (nothing clicked yet),
  # req() silently stops execution. The time series plot shows nothing until
  # the user selects a station. This avoids errors on startup.
  wq_station <- reactive({
    req(rv$selected_station)
    wq_filtered() |>
      filter(station_id == rv$selected_station) |>
      arrange(date)
  })

  # -- 8c. Selected watershed as an sf polygon object -----------------------
  # Used to: (1) highlight the polygon on the map, (2) clip the NLCD raster
  selected_ws <- reactive({
    req(rv$selected_watershed)
    watersheds |> filter(huc8 == rv$selected_watershed)
  })

  # -- 8d. NLCD raster clipped to the selected watershed --------------------
  # [CONCEPT] This is the core RASTER-VECTOR OPERATION:
  #   terra::vect()  converts the sf polygon to a terra SpatVector
  #   terra::mask()  sets all pixels OUTSIDE the polygon to NA
  #   terra::crop()  trims the raster extent to the polygon bounding box
  #   Together: only pixels inside the watershed boundary are retained.
  #
  # [WHY]     This answers the question: "what land cover exists within THIS
  #           specific watershed?" Wrapping it in reactive() means it only
  #           re-runs when the selected watershed changes - not on every input.
  nlcd_in_ws <- reactive({
    req(rv$selected_watershed)
    ws <- selected_ws()
    tryCatch({
      ws_vect <- vect(ws)                  # sf  -> terra SpatVector
      crop(mask(nlcd, ws_vect), ws_vect)   # mask then crop to polygon
    }, error = function(e) NULL)           # return NULL on any spatial error
  })

  # -- 8e. Pixel count summary for the clipped raster -> tidy data frame -----
  # values() extracts all non-NA pixel values as a vector.
  # We count occurrences of each class code, join the human-readable labels,
  # and calculate percentage cover for the bar chart y-axis.
  nlcd_summary <- reactive({
    r_clip <- nlcd_in_ws()
    req(!is.null(r_clip))
    vals <- as.integer(values(r_clip, na.rm = TRUE))
    tibble(value = vals) |>
      count(value) |>
      left_join(nlcd_lookup, by = "value") |>
      mutate(pct = round(100 * n / sum(n), 1)) |>
      arrange(desc(n))
  })

  # -- 8f. Summary statistics per station (drives the DT table) -------------
  # Collapses wq_filtered() to one row per station with descriptive stats.
  # Re-runs automatically when the date range or parameter changes.
  ws_summary <- reactive({
    wq_filtered() |>
      group_by(station_id, station_name) |>
      summarise(
        N    = n(),
        Mean = round(mean(value, na.rm = TRUE), 2),
        SD   = round(sd(value,   na.rm = TRUE), 2),
        Min  = round(min(value,  na.rm = TRUE), 2),
        Max  = round(max(value,  na.rm = TRUE), 2),
        .groups = "drop"
      ) |>
      rename(Station = station_name)
  })


  # ============================================================================
  # STEP 9 - BASE MAP  (renderLeaflet)
  # ----------------------------------------------------------------------------
  # [CONCEPT] renderLeaflet({ }) runs ONCE at startup and draws the empty base
  #           map. Data layers are NOT added here - they are added by observe()
  #           blocks in Step 10 using leafletProxy().
  #
  # [WHY]     Separating base map creation from layer management is the key
  #           Leaflet-in-Shiny pattern. If all the layer code were inside
  #           renderLeaflet(), the entire map would re-draw from scratch every
  #           time the user moved the date slider. leafletProxy() modifies only
  #           what changed, keeping the map stable and the viewport fixed.
  #
  # [DO]      Comment out all the observe() blocks in Step 10, run the app,
  #           and confirm you see just an empty basemap centred on Baltimore.
  #           Then un-comment Step 10 to add the data layers on top.
  # ============================================================================

  output$map <- renderLeaflet({
    leaflet() |>
      addProviderTiles(providers$CartoDB.Positron,  group = "Basemap") |>
      addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") |>
      # Create a custom pane for the NLCD layer with a z-index above the
      # tile pane (400) but below the overlay pane (500) where polygons live
      addMapPane("nlcd_pane",       zIndex = 420) |>  # NLCD sits above base tiles
      addMapPane("watershed_pane",  zIndex = 430) |>  # watersheds sit above NLCD
      # Add NLCD once at startup, hidden by default
      addRasterImage(
        x        = nlcd_raster,
        colors   = nlcd_pal,
        opacity  = 0.6,
        group    = "NLCD",
        maxBytes = 8 * 1024 * 1024,
        options  = pathOptions(pane = "nlcd_pane")
      ) |>
      hideGroup("NLCD") |>
      addLayersControl(
        baseGroups = c("Basemap", "Satellite"),
        options    = layersControlOptions(collapsed = FALSE)
      ) |>
      setView(lng = -76.50, lat = 39.25, zoom = 9)
  })


  # ============================================================================
  # STEP 10 - MAP LAYER OBSERVERS  (observe + leafletProxy)
  # ----------------------------------------------------------------------------
  # [CONCEPT] observe({ }) runs whenever ANY reactive value it reads changes.
  #           Unlike reactive(), it has NO return value - it exists purely to
  #           cause SIDE EFFECTS (here: adding or removing map layers).
  #
  #           leafletProxy("map") targets the already-rendered Leaflet map
  #           and modifies it in-place without destroying it or resetting the
  #           user's current zoom level and pan position.
  #
  # [WHY]     Each layer has its OWN observe() block. This means:
  #           - toggling show_watersheds only re-runs the watershed observer
  #           - changing the date slider only re-runs the station observer
  #             (because that observer reads wq_filtered(), which reads the slider)
  #           - the NLCD layer is untouched unless show_nlcd changes
  #           This is efficient, targeted reactivity - only the minimum work runs.
  #
  # [DO]      Toggle each checkbox in the sidebar and watch the corresponding
  #           layer appear and disappear independently of the others.
  #           Then change the variable dropdown - watch only the station
  #           markers re-colour; the watershed polygons are unaffected.
  # ============================================================================

  # -- 10a. Watershed polygons -----------------------------------------------
  # Triggered by: input$show_watersheds
  # layerId = ~huc8 is critical - it is what input$map_shape_click$id returns
  # when the user clicks a polygon (used in the event handler in Step 11).
  # options = pathOptions(interactive = FALSE) on the fill means marker clicks
  # pass through the polygon to the markers beneath. We still capture polygon
  # clicks via the outline (weight = 2) which remains interactive.
  observe({
    if (!input$show_watersheds) {
      leafletProxy("map") |> clearGroup("Watersheds")
      return()   # early return - don't add layers if checkbox is off
    }
    leafletProxy("map") |>
      clearGroup("Watersheds") |>
      addPolygons(
        data        = watersheds,
        group       = "Watersheds",
        layerId     = ~huc8,
        fillColor   = "#4A90D9",
        fillOpacity = 0.10,
        color       = "#1a5fa8",
        weight      = 2.5,
        opacity     = 1.0,
        options     = pathOptions(pane = "watershed_pane"),
        highlight   = highlightOptions(
          weight       = 4,
          color        = "#FFD700",
          fillOpacity  = 0.25,
          bringToFront = FALSE
        ),
        label = ~paste0(huc8_name, " watershed"),
        popup = ~paste0(
          "<b>", huc8_name, "</b><br>",
          "HUC8: ", huc8, "<br>",
          "Area: ", area_km2, " km2"
        )
      )
  })

  # -- 10b. Water quality station markers ------------------------------------
  # Triggered by: input$show_stations AND any change to wq_filtered()
  # (because this observer reads wq_filtered(), which depends on
  # input$variable and input$date_range - those changes propagate here)
  # Markers are colour-coded by the current mean value using a continuous scale.
  observe({
    if (!input$show_stations) {
      leafletProxy("map") |> clearGroup("WQ Stations")
      return()
    }

    # Compute per-station mean for the currently filtered data
    station_means <- wq_filtered() |>
      group_by(station_id) |>
      summarise(mean_val = mean(value, na.rm = TRUE), .groups = "drop")

    st_data <- stations |> left_join(station_means, by = "station_id")

    # colorNumeric() creates a palette function: given a number, returns a colour
    # pal is used for marker colours; pal_rev is used for the legend only
    # so the legend reads high (dark red) at top to low (yellow) at bottom
    pal     <- colorNumeric("YlOrRd", domain = st_data$mean_val)
    pal_rev <- colorNumeric("YlOrRd", domain = st_data$mean_val, reverse = TRUE)

    leafletProxy("map") |>
      clearGroup("WQ Stations") |>
      addCircleMarkers(
        data        = st_data,
        lng         = ~lon,
        lat         = ~lat,
        group       = "WQ Stations",
        layerId     = ~station_id,
        radius      = 8,
        fillColor   = ~pal(mean_val),
        fillOpacity = 0.9,
        color       = "#333",
        weight      = 1,
        options     = pathOptions(pane = "markerPane"),
        label = ~paste0(station_name, ": ",
                        round(mean_val, 2), " ", param_units[input$variable]),
        popup = ~paste0(
          "<b>", station_name, "</b><br>",
          "Mean: <b>", round(mean_val, 2), " ",
          param_units[input$variable], "</b>"
        )
      ) |>
      addLegend(
        position    = "bottomright",
        pal         = pal_rev,
        values      = st_data$mean_val,
        title       = paste0("Mean<br>", param_units[input$variable]),
        layerId     = "wq_legend",
        labFormat   = labelFormat(
          transform = function(x) sort(x, decreasing = TRUE)
        )
      )
  })

  # -- 10c. NLCD raster overlay ----------------------------------------------
  # [CONCEPT] The NLCD raster is added to the map ONCE at startup (Step 9)
  #           and simply shown or hidden using showGroup/hideGroup.
  #           This is more robust than clearGroup/addRasterImage because the
  #           layer stays in Leaflet's internal layer stack regardless of which
  #           basemap is active — switching basemaps never removes it.
  #
  #           FOR LARGE RASTERS IN PRODUCTION, use a tile server instead:
  #           A tile server pre-slices the raster into 256x256px tiles at
  #           multiple zoom levels (like Google Maps). The browser only requests
  #           tiles for the current viewport - never the whole image at once.
  #           Options in R:
  #             - leaflet.extras2::addCOG()  Cloud Optimized GeoTIFF, no server needed
  #             - titiler                    modern cloud-native tile server
  #             - geoserver                 full-featured open source tile server
  #             - gdal2tiles                pre-generate static tile directories
  #           The tradeoff: tile servers require more infrastructure but handle
  #           rasters of any size with no browser performance penalty.
  # Triggered by: input$show_nlcd
  observe({
    if (!input$show_nlcd) {
      leafletProxy("map") |> hideGroup("NLCD")
    } else {
      leafletProxy("map") |> showGroup("NLCD")
    }
  })

  # -- 10e. Highlight selected watershed ------------------------------------
  # Triggered by: rv$selected_watershed (set in the click handler below)
  # Draws an orange polygon on top of whichever watershed was clicked,
  # giving the user a clear visual cue of what is driving the lower panels.
  observe({
    req(rv$selected_watershed)
    ws <- selected_ws()
    leafletProxy("map") |>
      clearGroup("selected_ws") |>
      addPolygons(
        data        = ws,
        group       = "selected_ws",
        fillColor   = "#FF6B35",
        fillOpacity = 0.35,
        color       = "#c0390b",
        weight      = 2.5
      )
  })

  # -- 10f. Highlight selected station --------------------------------------
  # Triggered by: rv$selected_station (set by map marker click OR table row click)
  # Draws a yellow ring around the selected station marker so the user can
  # always see which station is driving the time series plot, regardless of
  # whether they selected it from the map or from the summary table.
  observe({
    # Clear the highlight whenever selection is empty
    if (is.null(rv$selected_station)) {
      leafletProxy("map") |> clearGroup("selected_station")
      return()
    }
    st <- stations |> filter(station_id == rv$selected_station)
    req(nrow(st) > 0)
    leafletProxy("map") |>
      clearGroup("selected_station") |>
      addCircleMarkers(
        data        = st,
        lng         = ~lon,
        lat         = ~lat,
        group       = "selected_station",
        radius      = 14,              # larger than the base marker (radius 8)
        fillColor   = "transparent",
        fillOpacity = 0,
        color       = "#FFD700",       # yellow ring
        weight      = 3,
        options     = pathOptions(pane = "markerPane")
      )
  })


  # ============================================================================
  # STEP 11 - MAP EVENT HANDLERS  (observeEvent)
  # ----------------------------------------------------------------------------
  # [CONCEPT] observeEvent(trigger, { handler }) fires the handler ONLY when
  #           the named trigger changes. Unlike observe(), it ignores all other
  #           reactive dependencies inside the handler block - making click
  #           handlers clean and predictable.
  #
  # [WHY]     Map clicks are EVENTS, not persistent input values. Leaflet fires
  #           them as special reactive inputs:
  #             input$map_shape_click   - fires when a polygon layerId is clicked
  #             input$map_marker_click  - fires when a circle marker is clicked
  #             input$map_click         - fires on any map click (including blank)
  #           We catch them here and write to rv$selected_*, which then cascades
  #           through the reactive expressions in Step 8 to update all panels.
  #
  # [DO]      This is the central demonstration of reactive linkage.
  #           Click a watershed -> watch dist_plot and summary_table update.
  #           Click a station   -> watch ts_plot update and its row highlight
  #                               in the table.
  #           Click a table row -> watch the map pan to that station and the
  #                               time series update. Linkage works both ways!
  #           Click blank map  -> everything resets.
  #           All of that behaviour comes from just three observeEvent() blocks.
  # ============================================================================

  # -- Polygon click -> update selected watershed ----------------------------
  # input$map_shape_click$id returns the layerId we set in addPolygons() above
  observeEvent(input$map_shape_click, {
    click <- input$map_shape_click
    # Guard: only accept IDs that belong to our watershed layer
    # (prevents the orange highlight polygon from triggering itself)
    if (!is.null(click$id) && click$id %in% watersheds$huc8) {
      rv$selected_watershed <- click$id   # writing here invalidates selected_ws(),
                                          # nlcd_in_ws(), nlcd_summary() -> dist_plot
    }
  })

  # -- Marker click -> update selected station --------------------------------
  # input$map_marker_click$id returns the layerId we set in addCircleMarkers()
  observeEvent(input$map_marker_click, {
    click <- input$map_marker_click
    if (!is.null(click$id) && click$id %in% stations$station_id) {
      rv$selected_station <- click$id
    }
  })

  # -- Table row click -> update selected station ----------------------------
  # [CONCEPT] DT fires input$summary_table_rows_selected whenever the user
  #           clicks a row. We translate the row index back to a station_id
  #           and write to rv$selected_station - the same reactive value that
  #           map marker clicks write to. This means the table and map are
  #           bidirectionally linked: clicking either one updates the other.
  #           The yellow ring highlight (observer 10f) handles the visual cue.
  observeEvent(input$summary_table_rows_selected, {
    row <- input$summary_table_rows_selected
    if (!is.null(row) && length(row) > 0) {
      df <- ws_summary()
      station_name <- df$Station[row]
      station_id   <- stations$station_id[stations$station_name == station_name]
      if (length(station_id) > 0) {
        rv$selected_station <- station_id
      }
    }
  })

  # -- Blank map click -> clear all selections --------------------------------
  observeEvent(input$map_click, {
    rv$selected_watershed <- NULL
    rv$selected_station   <- NULL
    leafletProxy("map") |>
      clearGroup("selected_ws") |>
      clearGroup("selected_station")
  })


  # ============================================================================
  # STEP 12 - TIME SERIES PLOT  (renderPlotly)
  # ----------------------------------------------------------------------------
  # [CONCEPT] renderPlotly({ }) re-runs whenever any reactive it reads changes:
  #             rv$selected_station  - when user clicks a different station
  #             wq_station()         - which depends on wq_filtered()
  #             wq_filtered()        - which depends on input$variable + input$date_range
  #
  #           This means the plot updates for THREE different user actions:
  #             1. Clicking a station marker on the map
  #             2. Moving the date range slider
  #             3. Changing the parameter dropdown
  #
  # [WHY]     This is "linked panels" in action - a single reactive expression
  #           (wq_filtered) serves as a shared data hub for multiple outputs.
  #           Changing the date range propagates to the time series AND the
  #           summary table simultaneously with zero extra code.
  #
  # [DO]      Run the app. Notice:
  #           • No station selected -> faint overview of all stations
  #           • Click a station    -> focused view + 6-month rolling average line
  #           • Move the date slider while a station is selected -> plot updates
  #           • Change the parameter dropdown -> y-axis unit and values change
  # ============================================================================

  # Dynamic subtitle: guides the user when nothing is selected, shows station
  # name + current parameter when a WQ station is selected
  output$ts_title <- renderUI({
    if (is.null(rv$selected_station)) {
      tags$p(
        style = "color:#888; font-size:12px; margin:0 0 6px",
        "Click a station marker on the map to focus its time series."
      )
    } else {
      st_name     <- stations$station_name[stations$station_id == rv$selected_station]
      param_label <- names(param_choices)[param_choices == input$variable]
      tags$p(
        style = "color:#333; font-size:12px; font-weight:600; margin:0 0 6px",
        paste0(st_name, " - ", param_label)
      )
    }
  })

  output$ts_plot <- renderPlotly({

    # STATE A: No station selected - show all stations as a faint overview
    if (is.null(rv$selected_station)) {
      df <- wq_filtered() |>
        group_by(station_id, date) |>
        summarise(value = mean(value), .groups = "drop") |>
        left_join(stations |> select(station_id, station_name), by = "station_id")

      plot_ly(
        df,
        x             = ~date,
        y             = ~value,
        color         = ~station_name,
        type          = "scatter",
        mode          = "lines",
        line          = list(width = 1),
        hovertemplate = "%{x|%Y-%m}: %{y:.2f}<extra>%{fullData.name}</extra>"
      ) |>
        layout(
          xaxis    = list(title = ""),
          yaxis    = list(title = param_units[input$variable]),
          legend   = list(orientation = "h", y = -0.3, font = list(size = 13)),
          margin   = list(t = 10),
          dragmode = FALSE
        ) |>
        config(modeBarButtonsToRemove = list("select2d", "lasso2d"))

    } else {

      # STATE B: Station selected - focused single-station view with smoother
      df <- wq_station()

      # zoo::rollmean() computes a k-period moving average
      # fill = NA: first/last (k-1)/2 values have insufficient window -> shown as gap
      df <- df |>
        mutate(roll_avg = zoo::rollmean(value, k = 6, fill = NA))

      plot_ly(
        df,
        x             = ~date,
        y             = ~value,
        type          = "scatter",
        mode          = "lines+markers",
        name          = "Monthly",
        line          = list(color = "#1a6ebd", width = 2),
        marker        = list(color = "#1a6ebd", size  = 4),
        hovertemplate = "%{x|%Y-%m}: %{y:.2f}<extra></extra>"
      ) |>
        add_lines(
          x    = ~date,
          y    = ~roll_avg,
          name = "6-month avg",
          line = list(color = "#e74c3c", width = 2, dash = "dot"),
          hoverinfo = "skip"   # don't show tooltip for the smoother line
        ) |>
        layout(
          xaxis    = list(title = ""),
          yaxis    = list(title = param_units[input$variable]),
          legend   = list(orientation = "h", y = -0.3),
          margin   = list(t = 10),
          dragmode = FALSE
        ) |>
        config(modeBarButtonsToRemove = list("select2d", "lasso2d"))
    }
  })


  # ============================================================================
  # STEP 13 - LAND COVER DISTRIBUTION PLOT  (renderPlotly)
  # ----------------------------------------------------------------------------
  # [CONCEPT] This plot demonstrates the full RASTER-VECTOR QUERY PIPELINE:
  #
  #           User clicks polygon
  #             -> rv$selected_watershed changes
  #               -> selected_ws() re-runs  (sf polygon)
  #                 -> nlcd_in_ws() re-runs  (terra crop + mask)
  #                   -> nlcd_summary() re-runs  (pixel count table)
  #                     -> dist_plot re-renders  (bar chart)
  #
  # [WHY]     Five reactive expressions chain together to answer:
  #           "What percentage of THIS watershed is forest / developed / wetland?"
  #           Each step is cached independently, so clicking the same watershed
  #           twice doesn't recompute the raster clipping.
  #
  # [DO]      Enable the NLCD map layer (checkbox in sidebar) and click each
  #           watershed polygon in turn. Watch the bar chart update to reflect
  #           the land cover you can visually see on the map within that polygon.
  #           The colours in the bar chart use the official NLCD colour scheme.
  # ============================================================================

  output$dist_title <- renderUI({
    if (is.null(rv$selected_watershed)) {
      tags$p(
        style = "color:#888; font-size:12px; margin:0 0 6px",
        "Click a watershed polygon to see its land cover breakdown."
      )
    } else {
      ws_name <- watersheds$huc8_name[watersheds$huc8 == rv$selected_watershed]
      tags$p(
        style = "color:#333; font-size:12px; font-weight:600; margin:0 0 6px",
        paste0(ws_name, " watershed")
      )
    }
  })

  output$dist_plot <- renderPlotly({

    # STATE A: No watershed selected - show full region overview
    if (is.null(rv$selected_watershed)) {
      vals <- as.integer(values(nlcd, na.rm = TRUE))
      df <- tibble(value = vals) |>
        count(value) |>
        left_join(nlcd_lookup, by = "value") |>
        mutate(pct = round(100 * n / sum(n), 1)) |>
        arrange(desc(n))

    } else {
      # STATE B: Watershed selected - use the clipped raster summary
      df <- nlcd_summary()
      req(nrow(df) > 0)
    }

    plot_ly(
      df,
      x             = ~reorder(label, -pct),  # sort bars by descending coverage
      y             = ~pct,
      type          = "bar",
      marker        = list(color = ~color),   # official NLCD colours per class
      hovertemplate = "%{x}<br>%{y:.1f}%<extra></extra>"
    ) |>
      layout(
        xaxis      = list(title = "", tickangle = -40, tickfont = list(size = 12)),
        yaxis      = list(title = "% cover"),
        margin     = list(b = 100, t = 10),
        # dragmode = FALSE disables lasso/box select on this chart, preventing
        # Plotly from dimming unselected bars and requiring a page refresh to reset
        dragmode   = FALSE
      ) |>
      config(
        # Remove the lasso and box select buttons from the plotly toolbar entirely
        modeBarButtonsToRemove = list("select2d", "lasso2d")
      )
  })


  # ============================================================================
  # STEP 14 - SUMMARY STATISTICS TABLE  (renderDT)
  # ----------------------------------------------------------------------------
  # [CONCEPT] DT::datatable() renders an interactive HTML table. renderDT({ })
  #           re-runs whenever ws_summary() changes - which happens when
  #           input$variable or input$date_range changes.
  #
  # [WHY]     Linking the table to the same filtered dataset as the plots means
  #           statistics in the table always match what the plots are showing.
  #           The selected station's row is highlighted to reinforce the map-
  #           table linkage - clicking a marker on the map highlights a row here.
  #
  # [DO]      Move the date slider -> watch Mean / SD / Min / Max update.
  #           Click a station on the map -> its row highlights in the table.
  #           Change the parameter -> all statistics recalculate.
  #           Notice the colour bar behind the Mean column for quick scanning.
  # ============================================================================

  output$summary_table <- renderDT({
    df <- ws_summary()

    # Find which row corresponds to the currently selected station (for highlighting)
    sel_row <- if (!is.null(rv$selected_station)) {
      which(
        df$Station == stations$station_name[
          stations$station_id == rv$selected_station
        ]
      )
    } else {
      integer(0)   # empty selection = no row highlighted
    }

    datatable(
      df |> dplyr::select(-station_id),    # hide the internal ID column from display
      selection  = list(mode = "single", selected = sel_row),
      rownames   = FALSE,
      options    = list(
        pageLength = 8,
        dom        = "t",           # "t" = table only, suppress search/length controls
        scrollY    = "280px",
        scrollCollapse = TRUE,      # shrinks if fewer rows than scrollY height
        columnDefs = list(
          list(className = "dt-center", targets = 1:5)
        )
      ),
      class = "compact stripe hover"
    ) |>
      # styleColorBar: adds a proportional blue bar behind each Mean value cell
      # This makes it easy to spot high/low stations at a glance
      formatStyle(
        columns            = "Mean",
        background         = styleColorBar(range(df$Mean, na.rm = TRUE), "#90caf9"),
        backgroundSize     = "100% 80%",
        backgroundRepeat   = "no-repeat",
        backgroundPosition = "center"
      )
  })


  # ============================================================================
  # STEP 15 - SUGGESTED EXERCISES  (try these as a group)
  # ----------------------------------------------------------------------------
  # After walking through the full app, try these modifications to reinforce
  # the core concepts. Each one is self-contained and won't break the app.
  #
  # A. ADD A NEW INPUT THAT LINKS TO AN EXISTING PLOT
  #    In the UI sidebar, add:
  #      numericInput("smooth_k", "Smoothing window (months)", value = 6, min = 2, max = 24)
  #    In output$ts_plot, replace the hardcoded k = 6 with k = input$smooth_k
  #    Run the app - the rolling average line now responds to the new control.
  #    Q: Which render function re-ran? Which ones did NOT re-run? Why?
  #
  # B. ADD A NEW OUTPUT PANEL
  #    In the UI, add a fourth box in Row 2 (width = 3, shift others to fit).
  #    Add this output inside the new box: plotlyOutput("scatter_plot")
  #    In the server, add:
  #      output$scatter_plot <- renderPlotly({
  #        req(rv$selected_watershed)
  #        df <- wq_filtered() |>
  #          left_join(stations, by = c("station_id","station_name","lat","lon")) |>
  #          filter(station_id %in% stations$station_id)
  #        plot_ly(df, x = ~date, y = ~value, color = ~station_name,
  #                type = "scatter", mode = "markers", marker = list(size = 4))
  #      })
  #    Q: What inputs trigger this new plot? Did you have to wire anything up?
  #
  # C. ADD A DOWNLOAD BUTTON
  #    In the UI, add below the summary table:
  #      downloadButton("dl_csv", "Download filtered data")
  #    In the server, add:
  #      output$dl_csv <- downloadHandler(
  #        filename = function() paste0("wq_", input$variable, "_", Sys.Date(), ".csv"),
  #        content  = function(file) readr::write_csv(wq_filtered(), file)
  #      )
  #    Q: The filename changes with the parameter. What makes that work?
  #
  # D. SWAP IN YOUR OWN DATA
  #    Un-comment the data loading block in Step 2.
  #    Update the file paths to point to your real files.
  #    Comment out the entire simulated data block in Step 3.
  #    Run the app - it should work with no other changes if column names match.
  #    Q: If your WQ CSV has a column called "measure" instead of "value",
  #       what is the minimum number of places you'd need to rename it?
  #       (Hint: check wq_filtered() and ws_summary() in Step 8.)
  # ============================================================================

}   # end server()


# ==============================================================================
# STEP 16 - LAUNCH THE APP
# ------------------------------------------------------------------------------
# [CONCEPT] shinyApp(ui, server) wires the UI and server together and hands
#           control to Shiny's internal web server.
#
#           In RStudio, clicking "Run App" at the top of this file calls
#           this line automatically.
#
# [DO]      Click "Run App" in RStudio, or run this line in the console.
#           The app opens in your default browser or the RStudio viewer pane.
#           Press the red Stop button in RStudio (or Escape) to close it.
# ==============================================================================

shinyApp(ui = ui, server = server)


# ==============================================================================
# STEP 17 - SHARING YOUR APP  (optional - for after the workshop)
# ------------------------------------------------------------------------------
# [CONCEPT] A Shiny app running in RStudio is only accessible on YOUR machine
#           at a local address like http://127.0.0.1:PORT. To share it with
#           others you need to either deploy it to a server or tunnel the
#           local port to a public URL.
#
# [WHY]     Understanding how to share your app is the final step between
#           "it works on my laptop" and "anyone can use this." Both options
#           below are free and work without institutional infrastructure.
# ==============================================================================

# ------------------------------------------------------------------------------
# OPTION A - shinyapps.io  (recommended: permanent URL, no terminal needed)
# ------------------------------------------------------------------------------
# [CONCEPT] shinyapps.io is a hosting platform run by Posit (the RStudio
#           company). You push your app from RStudio and it gets a permanent
#           public URL that works even when your laptop is off.
#
# [DO]      1. Create a free account at https://www.shinyapps.io
#           2. In RStudio, install the deployment package:
#                install.packages("rsconnect")
#           3. Connect your account (tokens are on your shinyapps.io dashboard):
#                library(rsconnect)
#                rsconnect::setAccountInfo(
#                  name   = "YOUR_ACCOUNT_NAME",
#                  token  = "YOUR_TOKEN",
#                  secret = "YOUR_SECRET"
#                )
#           4. Deploy with one command (run from the same folder as app.R):
#                rsconnect::deployApp()
#           5. Your app gets a permanent URL like:
#                https://YOUR_NAME.shinyapps.io/YOUR_APP_NAME
#
#           Free tier allows 5 apps and 25 active hours/month.
#           The URL is stable - share it in papers, emails, or course materials.

# ------------------------------------------------------------------------------
# OPTION B - ngrok  (quick: temporary tunnel, no deployment, framework agnostic)
# ------------------------------------------------------------------------------
# [CONCEPT] ngrok creates a secure tunnel from a public URL to a port on your
#           local machine. It does NOT care what is running on that port -
#           the same workflow works for Shiny, Python Streamlit, Flask,
#           FastAPI, Dash, or any other local web app.
#
# [WHY]     ngrok is useful for live demos, quick sharing during a meeting,
#           or testing how your app behaves for external users - without
#           going through a full deployment. It is one of the tools covered
#           in the presentation component of this workshop.
#
# [DO]      SETUP (one time per machine):
#           1. Install ngrok:
#                Mac:     brew install ngrok/ngrok/ngrok
#                Windows: download from https://ngrok.com/download
#                Linux:   snap install ngrok
#           2. Create a free account at https://ngrok.com
#           3. Register your auth token (find it on your ngrok dashboard):
#                ngrok config add-authtoken YOUR_TOKEN_HERE
#
#           EACH SESSION:
#           1. Click "Run App" in RStudio - the app opens in your browser
#           2. Check the browser URL - note the port number, e.g. 127.0.0.1:4533
#           3. Open a NEW terminal (not the R console) and run:
#                ngrok http 4533       # replace 4533 with your actual port
#           4. ngrok prints a forwarding URL like:
#                https://abc123.ngrok-free.app -> http://localhost:4533
#           5. Share ONLY the left side: https://abc123.ngrok-free.app
#              (the -> localhost part is just ngrok showing you the routing)
#
#           IMPORTANT LIMITATIONS OF THE FREE TIER:
#           - The URL changes every time you restart the tunnel
#           - The tunnel closes when you close the terminal
#           - Sessions time out after ~2 hours
#           - Keep BOTH the Shiny app AND the ngrok terminal running
#             for the link to stay active
#
#           For a permanent shareable link, use Option A (shinyapps.io) instead.

