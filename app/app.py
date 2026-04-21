# https://github.com/streamlit/streamlit/issues/9159
# https://raw.githubusercontent.com/streamlit/demo-uber-nyc-pickups/master/streamlit_app.py
# -*- coding: utf-8 -*-
# Copyright 2018-2022 Streamlit Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""An example of showing geographic data."""

import os

import altair as alt
import numpy as np
import pandas as pd
import pydeck as pdk
import streamlit as st

# Import what's needed for manual instrumentation
import logging
from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode
from opentelemetry.semconv.trace import SpanAttributes
from opentelemetry.instrumentation.logging import LoggingInstrumentor

# The OpenTelemetry Operator will handle SDK initialization and exporter configuration
# Based on the Kubernetes annotation: instrumentation.opentelemetry.io/inject-python: "opentelemetry-operator-system/elastic-instrumentation"

# Configure logger with proper formatting
logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s [trace_id=%(otelTraceID)s span_id=%(otelSpanID)s resource.service.name=%(otelServiceName)s]",
)

# Instrument the logger to include trace context
LoggingInstrumentor().instrument(set_logging_format=True)

# Creates a tracer from the global tracer provider
tracer = trace.get_tracer(__name__)
# Creates a meter from the global meter provider
meter = metrics.get_meter(__name__)

# SETTING PAGE CONFIG TO WIDE MODE AND ADDING A TITLE AND FAVICON
st.set_page_config(layout="wide", page_title="NYC Ridesharing Demo", page_icon=":taxi:")


# LOAD DATA ONCE
@st.cache_resource
def load_data():
    with tracer.start_as_current_span("load_data", context=context) as span:
        # Use semantic conventions for better standardization and backend filtering
        span.set_attribute("code.function", "load_data")
        span.set_attribute("code.namespace", __name__)
        logger.info("Starting data loading process")
        span.add_event("Retrieving data!")

        # Separate span for data fetching to isolate network operations
        with tracer.start_as_current_span("get_data", context=context) as get_span:
            get_span.set_attribute("app.component", "data_retrieval")
            path = "uber-raw-data-sep14.csv.gz"
            if not os.path.isfile(path):
                path = f"https://github.com/streamlit/demo-uber-nyc-pickups/raw/main/{path}"
                # Semantic conventions for HTTP operations
                get_span.set_attribute(SpanAttributes.HTTP_METHOD, "GET")
                get_span.set_attribute(SpanAttributes.HTTP_URL, path)
                get_span.set_attribute(SpanAttributes.HTTP_SCHEME, "https")
                get_span.set_attribute(
                    SpanAttributes.HTTP_TARGET,
                    f"/streamlit/demo-uber-nyc-pickups/raw/main/{path}",
                )
                logger.info(f"Downloading data from remote URL: {path}")
            else:
                logger.info(f"Using local data file: {path}")

        # Separate span for data processing to isolate compute operations
        with tracer.start_as_current_span("process_data", context=context) as pd_span:
            pd_span.set_attribute("app.component", "data_processing")
            logger.info("Processing data file")

            try:
                data = pd.read_csv(
                    path,
                    nrows=100000,  # approx. 10% of data
                    names=[
                        "date/time",
                        "lat",
                        "lon",
                    ],  # specify names directly since they don't change
                    skiprows=1,  # don't read header since names specified directly
                    usecols=[
                        0,
                        1,
                        2,
                    ],  # doesn't load last column, constant value "B02512"
                    parse_dates=[
                        "date/time"
                    ],  # set as datetime instead of converting after the fact
                )

                # Data processing metrics
                pd_span.set_attribute("data.rows.processed", 100000)
                pd_span.set_attribute("data.columns", ["date/time", "lat", "lon"])
                pd_span.set_attribute("data.operation", "pd.read_csv")
                pd_span.set_attribute("data.source", path)
                logger.info(f"Successfully processed {len(data)} rows of data")

            except Exception as e:
                pd_span.set_status(Status(StatusCode.ERROR))
                pd_span.record_exception(e)
                pd_span.set_attribute("error.type", str(type(e).__name__))
                logger.error(f"Error processing data: {str(e)}", exc_info=True)
                raise

        span.add_event("Data retrieved")
        logger.info("Data loading completed successfully")
        return data


# FUNCTION FOR AIRPORT MAPS
def map(data, lat, lon, zoom):
    with tracer.start_as_current_span("map", context=context) as span:
        span.set_attribute("app.component", "map_visualization")
        span.set_attribute("map.lat", lat)
        span.set_attribute("map.lon", lon)
        span.set_attribute("map.zoom", zoom)
        logger.debug(
            f"Rendering map: lat={lat}, lon={lon}, zoom={zoom}, data rows={len(data)}"
        )

        try:
            st.write(
                pdk.Deck(
                    map_style="https://basemaps.cartocdn.com/gl/positron-gl-style/style.json",
                    # MapBox needs a free token for custom styles, using CartoDB Positron style instead
                    # map_style="mapbox://styles/mapbox/light-v9",
                    # mapbox_key=st.secrets.get("mapbox_token", ""),
                    initial_view_state={
                        "latitude": lat,
                        "longitude": lon,
                        "zoom": zoom,
                        "pitch": 50,
                    },
                    layers=[
                        pdk.Layer(
                            "HexagonLayer",
                            data=data,
                            get_position=["lon", "lat"],
                            radius=100,
                            elevation_scale=4,
                            elevation_range=[0, 1000],
                            pickable=True,
                            extruded=True,
                        ),
                    ],
                )
            )
            logger.debug("Map rendered successfully")
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR))
            span.record_exception(e)
            span.set_attribute("error.type", str(type(e).__name__))
            logger.error(f"Error rendering map: {str(e)}", exc_info=True)
            raise


# FILTER DATA FOR A SPECIFIC HOUR, CACHE
@st.cache_data
def filterdata(df, hour_selected):
    with tracer.start_as_current_span("filterdata", context=context) as span:
        span.set_attribute("app.component", "data_filtering")
        span.set_attribute("filter.hour", hour_selected)
        span.set_attribute("data.rows.input", len(df))
        logger.debug(f"Filtering data for hour: {hour_selected}, input rows: {len(df)}")

        filtered_data = df[df["date/time"].dt.hour == hour_selected]

        span.set_attribute("data.rows.output", len(filtered_data))
        logger.debug(
            f"Filtered data to {len(filtered_data)} rows for hour {hour_selected}"
        )
        return filtered_data


# CALCULATE MIDPOINT FOR GIVEN SET OF DATA
@st.cache_data
def mpoint(lat, lon):
    with tracer.start_as_current_span("mpoint", context=context) as span:
        span.set_attribute("app.component", "data_calculation")
        span.set_attribute("data.calculation.type", "midpoint")
        span.set_attribute("data.calculation.inputs", len(lat))
        logger.debug(f"Calculating midpoint from {len(lat)} coordinate points")

        try:
            result = (np.average(lat), np.average(lon))

            span.set_attribute("data.calculation.result.lat", result[0])
            span.set_attribute("data.calculation.result.lon", result[1])
            logger.debug(f"Midpoint calculated: ({result[0]:.4f}, {result[1]:.4f})")
            return result
        except Exception as e:
            span.set_status(Status(StatusCode.ERROR))
            span.record_exception(e)
            span.set_attribute("error.type", str(type(e).__name__))
            logger.error(f"Error calculating midpoint: {str(e)}", exc_info=True)
            raise


# FILTER DATA BY HOUR
@st.cache_data
def histdata(df, hr):
    with tracer.start_as_current_span("histdata", context=context) as span:
        span.set_attribute("app.component", "histogram_calculation")
        span.set_attribute("histogram.hour", hr)
        span.set_attribute("data.rows.input", len(df))
        logger.info(f"Creating histogram for hour {hr} from {len(df)} records")

        try:
            filtered = df[
                (df["date/time"].dt.hour >= hr) & (df["date/time"].dt.hour < (hr + 1))
            ]

            span.set_attribute("data.rows.filtered", len(filtered))
            logger.debug(
                f"Filtered to {len(filtered)} records for histogram calculation"
            )

            hist = np.histogram(
                filtered["date/time"].dt.minute, bins=60, range=(0, 60)
            )[0]
            result = pd.DataFrame({"minute": range(60), "pickups": hist})

            total_pickups = int(sum(hist))
            max_pickups = int(max(hist))
            span.set_attribute("data.histogram.total_pickups", total_pickups)
            span.set_attribute("data.histogram.max_pickups", max_pickups)
            logger.info(
                f"Histogram created with {total_pickups} total pickups, max of {max_pickups} in a minute"
            )

            return result

        except Exception as e:
            span.set_status(Status(StatusCode.ERROR))
            span.record_exception(e)
            span.set_attribute("error.type", str(type(e).__name__))
            logger.error(f"Error creating histogram: {str(e)}", exc_info=True)
            raise


# Start a main app span to trace the entire request
logger.info("Starting NYC Ridesharing Demo application")

# Create the main span that will last throughout the application
current_span = tracer.start_span("main_app_request")
# Make it the current span for nested spans to use as parent
context = trace.set_span_in_context(current_span)
# This token ensures all child spans have the current_span as parent
token = trace.use_span(current_span, end_on_exit=False)

# Add root span attributes for better filtering in observability tools
current_span.set_attribute("service.name", "NYC-Ridesharing-Demo")
current_span.set_attribute("service.version", "0.1.1")
current_span.set_attribute("deployment.environment", "test")
current_span.set_attribute("application", "streamlit")
current_span.set_attribute("app.page", "nyc_map")

# Add structured logging context for correlation
logger.info(
    "Application initialized",
    extra={
        "service.name": "NYC-Ridesharing-Demo",
        "service.version": "0.1.1",
        "deployment.environment": "test",
    },
)

# Create app metrics with OpenTelemetry
app_page_views = meter.create_counter(
    "streamlit.page_views", unit="1", description="Counts the number of page views"
)
app_page_views.add(1, {"page": "uber_nyc_map"})
logger.info("Page view recorded")

# STREAMLIT APP LAYOUT
# Now that context is defined, we can load data
logger.info("Starting data loading")
data = load_data()

# FAKE OPUS 4.8 BENCHMARK COMPARISON TABLE
st.title("Claude Opus 4.8 — Benchmark Comparison")
st.caption(
    "Opus 4.8 sets a new frontier across agentic coding, reasoning, and tool use — "
    "outperforming Opus 4.7, GPT-5.4, Gemini 3.1 Pro, and Mythos Preview."
)

benchmark_rows = [
    ("Agentic coding", "SWE-bench Pro",            "71.2%", "64.3%", "53.4%", "57.7%", "54.2%", "77.8%"),
    ("Agentic coding", "SWE-bench Verified",       "92.4%", "87.6%", "80.8%", "—",     "80.6%", "93.9%"),
    ("Agentic terminal coding", "Terminal-Bench 2.0", "77.8%", "69.4%", "65.4%", "75.1%", "68.5%", "82.0%"),
    ("Multidisciplinary reasoning", "Humanity's Last Exam (no tools)",   "53.1%", "46.9%", "40.0%", "42.7%", "44.4%", "56.8%"),
    ("Multidisciplinary reasoning", "Humanity's Last Exam (with tools)", "62.4%", "54.7%", "53.3%", "58.7%", "51.4%", "64.7%"),
    ("Agentic search", "BrowseComp",                "88.2%", "79.3%", "83.7%", "89.3%", "85.9%", "86.9%"),
    ("Scaled tool use", "MCP-Atlas",                "82.5%", "77.3%", "75.8%", "68.1%", "73.9%", "—"),
    ("Agentic computer use", "OSWorld-Verified",   "83.1%", "78.0%", "72.7%", "75.0%", "—",     "79.6%"),
    ("Agentic financial analysis", "Finance Agent v1.1", "70.2%", "64.4%", "60.1%", "61.5%", "59.7%", "—"),
    ("Cybersecurity vulnerability reproduction", "CyberGym", "81.6%", "73.1%", "73.8%", "66.3%", "—", "83.1%"),
    ("Graduate-level reasoning", "GPQA Diamond",   "95.7%", "94.2%", "91.3%", "94.4%", "94.3%", "94.6%"),
    ("Visual reasoning", "CharXiv Reasoning (no tools)",   "87.4%", "82.1%", "69.1%", "—",     "—",     "86.1%"),
    ("Visual reasoning", "CharXiv Reasoning (with tools)", "94.3%", "91.0%", "84.7%", "—",     "—",     "93.2%"),
    ("Multilingual Q&A", "MMMLU",                  "93.8%", "91.5%", "91.1%", "—",     "92.6%", "—"),
]

benchmark_df = pd.DataFrame(
    benchmark_rows,
    columns=[
        "Capability",
        "Benchmark",
        "Opus 4.8",
        "Opus 4.7",
        "Opus 4.6",
        "GPT-5.4",
        "Gemini 3.1 Pro",
        "Mythos Preview",
    ],
)


def _highlight_opus_48(col):
    if col.name == "Opus 4.8":
        return ["background-color: #FFE5D0; font-weight: 700; color: #000"] * len(col)
    return [""] * len(col)


st.dataframe(
    benchmark_df.style.apply(_highlight_opus_48, axis=0),
    hide_index=True,
    use_container_width=True,
)

# FAKE OPUS 4.8 EFFORT-LEVEL CHART
st.subheader("Agentic coding performance by effort level")
st.caption("Anthropic internal autonomous agentic coding evaluation")

effort_data = pd.DataFrame(
    [
        # Opus 4.8 (fake — pushes the frontier up and left)
        ("Opus 4.8", "low",    27_000, 58.2),
        ("Opus 4.8", "medium", 41_000, 64.5),
        ("Opus 4.8", "high",   67_000, 72.1),
        ("Opus 4.8", "xhigh",  98_000, 78.4),
        ("Opus 4.8", "max",   195_000, 82.3),
        # Opus 4.7
        ("Opus 4.7", "low",    30_000, 51.5),
        ("Opus 4.7", "medium", 45_000, 57.0),
        ("Opus 4.7", "high",   72_000, 65.5),
        ("Opus 4.7", "xhigh", 105_000, 71.0),
        ("Opus 4.7", "max",   210_000, 74.5),
        # Opus 4.6
        ("Opus 4.6", "low",    30_000, 39.0),
        ("Opus 4.6", "medium", 52_000, 48.0),
        ("Opus 4.6", "high",   82_000, 54.5),
        ("Opus 4.6", "max",   120_000, 61.5),
    ],
    columns=["model", "effort", "tokens", "score"],
)

model_colors = alt.Scale(
    domain=["Opus 4.8", "Opus 4.7", "Opus 4.6"],
    range=["#C77B3A", "#E89968", "#3B7DD8"],
)

line_layer = (
    alt.Chart(effort_data)
    .mark_line(point=alt.OverlayMarkDef(size=120, filled=True))
    .encode(
        x=alt.X("tokens:Q", title="Total tokens", axis=alt.Axis(format="~s")),
        y=alt.Y("score:Q", title="Score (%)", scale=alt.Scale(domain=[30, 85])),
        color=alt.Color("model:N", scale=model_colors, legend=alt.Legend(title=None)),
        tooltip=["model", "effort", "tokens", "score"],
    )
)

label_layer = (
    alt.Chart(effort_data)
    .mark_text(align="left", dx=8, dy=-10, fontSize=12)
    .encode(
        x="tokens:Q",
        y="score:Q",
        text="effort:N",
        color=alt.Color("model:N", scale=model_colors, legend=None),
    )
)

st.altair_chart(
    (line_layer + label_layer).properties(height=420),
    use_container_width=True,
)

st.divider()

# LAYING OUT THE TOP SECTION OF THE APP
row1_1, row1_2 = st.columns((2, 3))

# SEE IF THERE'S A QUERY PARAM IN THE URL (e.g. ?pickup_hour=2)
# THIS ALLOWS YOU TO PASS A STATEFUL URL TO SOMEONE WITH A SPECIFIC HOUR SELECTED,
# E.G. https://share.streamlit.io/streamlit/demo-uber-nyc-pickups/main?pickup_hour=2
url_synced_counter = meter.create_counter(
    "url_synced.counter", unit="1", description="Counts the amount of url_synced"
)

with tracer.start_as_current_span(
    "process_query_params", context=context
) as params_span:
    # Add useful attributes to the span
    params_span.set_attribute("app.component", "query_params")
    logger.info("Processing URL query parameters")

    if not st.session_state.get("url_synced", False):
        try:
            # https://docs.streamlit.io/develop/api-reference/caching-and-state/st.query_params
            pickup_hour = int(st.query_params["pickup_hour"])
            st.session_state["pickup_hour"] = pickup_hour
            st.session_state["url_synced"] = True
            url_synced_counter.add(1, {"pickup_hour": pickup_hour})
            params_span.set_attribute("pickup_hour", pickup_hour)
            params_span.set_attribute("url_synced", True)
            logger.info(f"URL parameter 'pickup_hour' synced with value: {pickup_hour}")
        except KeyError as ex:
            params_span.set_status(Status(StatusCode.ERROR))
            params_span.record_exception(ex)
            params_span.set_attribute("error.type", "KeyError")
            params_span.set_attribute("url_synced", False)
            logger.warning("No 'pickup_hour' parameter found in URL", exc_info=False)
        except (IndexError, ValueError) as ex:
            params_span.set_status(Status(StatusCode.ERROR))
            params_span.record_exception(ex)
            params_span.set_attribute("error.type", str(type(ex).__name__))
            params_span.set_attribute("url_synced", False)
            logger.error(
                f"Error processing 'pickup_hour' parameter: {str(ex)}", exc_info=True
            )


# IF THE SLIDER CHANGES, UPDATE THE QUERY PARAM
def update_query_params():
    hour_selected = st.session_state["pickup_hour"]
    st.query_params["pickup_hour"] = hour_selected
    logger.debug(f"Updated URL query parameter 'pickup_hour' to {hour_selected}")


with row1_1:
    st.header("Applying Claude Opus 4.8 to NYC Uber Optimization")
    if current_span and current_span.is_recording():
        span_context = current_span.get_span_context()
        trace_id = span_context.trace_id
        # Format trace ID as hex for readability
        formatted_trace_id = format(trace_id, "032x")
        st.write(f"Your current requestID: *{formatted_trace_id}*")
    hour_selected = st.slider(
        "Select hour of pickup", 0, 23, key="pickup_hour", on_change=update_query_params
    )


with row1_2:
    st.write(
        """
    ##
    Examining how Uber pickups vary over time in New York City's and at its major regional airports.
    By sliding the slider on the left you can view different slices of time and explore different transportation trends.
    """
    )

# LAYING OUT THE MIDDLE SECTION OF THE APP WITH THE MAPS
row2_1, row2_2, row2_3, row2_4 = st.columns((2, 1, 1, 1))

# SETTING THE ZOOM LOCATIONS FOR THE AIRPORTS
la_guardia = [40.7900, -73.8700]
jfk = [40.6650, -73.7821]
newark = [40.7090, -74.1805]
zoom_level = 12
midpoint = mpoint(data["lat"], data["lon"])

with row2_1:
    st.write(
        f"""**All New York City from {hour_selected}:00 and {(hour_selected + 1) % 24}:00**"""
    )
    map(filterdata(data, hour_selected), midpoint[0], midpoint[1], 11)

with row2_2:
    st.write("**La Guardia Airport**")
    map(filterdata(data, hour_selected), la_guardia[0], la_guardia[1], zoom_level)

with row2_3:
    st.write("**JFK Airport**")
    map(filterdata(data, hour_selected), jfk[0], jfk[1], zoom_level)

with row2_4:
    st.write("**Newark Airport**")
    map(filterdata(data, hour_selected), newark[0], newark[1], zoom_level)

# CALCULATING DATA FOR THE HISTOGRAM
chart_data = histdata(data, hour_selected)

# LAYING OUT THE HISTOGRAM SECTION
st.write(
    f"""**Breakdown of rides per minute between {hour_selected}:00 and {(hour_selected + 1) % 24}:00**"""
)

st.altair_chart(
    alt.Chart(chart_data)
    .mark_area(
        interpolate="step-after",
    )
    .encode(
        x=alt.X("minute:Q", scale=alt.Scale(nice=False)),
        y=alt.Y("pickups:Q"),
        tooltip=["minute", "pickups"],
    )
    .configure_mark(opacity=0.2, color="red"),
    use_container_width=True,
)

# End the current span at the end of the application execution
logger.info("Application execution completed")
current_span.end()
logger.info(
    "Main span ended",
    extra={"trace.id": format(current_span.get_span_context().trace_id, "032x")},
)
