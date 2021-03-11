#include <osrm/table_parameters.hpp>
#include <osrm/engine_config.hpp>
#include <osrm/coordinate.hpp>
#include <osrm/status.hpp>
#include <osrm/json_container.hpp>
#include <osrm/osrm.hpp>

#include <cstdlib>

// set up wrapper functions so we can use ccall in julia to call out to cpp osrm
// see https://isocpp.org/wiki/faq/mixing-c-and-cpp#overview-mixing-langs

/**
 * Start up an OSRM Engine, and return an opaque pointer to it (on the Julia side, it can be a Ptr{Any}).
 * Pass in the path to a built OSRM graph, and the string for whether you are using multi-level Dijkstra (MLD)
 * or contraction hierarchies (CH)
 */
extern "C" struct osrm::OSRM * init_osrm (char * osrm_path, char * algorithm) {
    using namespace osrm;
    EngineConfig config;
    config.storage_config = {osrm_path};
    config.use_shared_memory = false;  // TODO this may have something to do with thread safety

    if (strcmp(algorithm, "ch") == 0) config.algorithm = EngineConfig::Algorithm::CH;
    else if (strcmp(algorithm, "mld") == 0) config.algorithm = EngineConfig::Algorithm::MLD;
    else throw std::runtime_error("algorithm must be 'ch' or 'mld'");

    osrm::OSRM * engn = new osrm::OSRM(config);

    return engn;
}

/**
 * Compute a distance matrix from origins to destinations, using the specified OSRM instance (an opaque Ptr{Any} returned
 * by init_osrm on the Julia side). Write results into the durations and distances arrays.
 */
extern "C" void distance_matrix(struct osrm::OSRM * osrm, size_t n_origins, double * origin_lats, double * origin_lons,
    size_t n_destinations, double * destination_lats, double * destination_lons, double * durations, double * distances) {
    using namespace osrm;

    // Create table parameters. concatenate origins and destinations into coordinates, set origin/destination references.
    TableParameters params;
    for (size_t i = 0; i < n_origins; i++) {
        params.sources.push_back(i);
        params.coordinates.push_back({util::FloatLongitude{origin_lons[i]}, util::FloatLatitude{origin_lats[i]}});
    }

    for (size_t i = 0; i < n_destinations; i++) {
        params.destinations.push_back(i + n_origins);
        params.coordinates.push_back({util::FloatLongitude{destination_lons[i]}, util::FloatLatitude{destination_lats[i]}});
    }

    params.annotations = TableParameters::AnnotationsType::All;

    engine::api::ResultT result = json::Object();    

    Status stat = osrm->Table(params, result);

    if (stat != Status::Ok) throw std::runtime_error("osrm failed!");

    auto &json_result = result.get<json::Object>();

    std::vector<json::Value> jdurations = json_result.values["durations"].get<json::Array>().values;
    std::vector<json::Value> jdistances = json_result.values["distances"].get<json::Array>().values;

    // copy it into the result array
    // jdurations, jdistances are multidimensional arrays

    for (size_t destination = 0; destination < n_destinations; destination++) {
        for (size_t origin = 0; origin < n_origins; origin++) {
            // julia arrays: col-major order
            size_t off = destination * n_origins + origin;
            durations[off] = double(jdurations.at(origin).get<json::Array>().values.at(destination).get<json::Number>().value);
            distances[off] = double(jdistances.at(origin).get<json::Array>().values.at(destination).get<json::Number>().value);
        }
    }
}

/**
 * Shut down an OSRM engine when it is no longer needed.
 */
extern "C" void stop_osrm (struct osrm::OSRM * engn) {
    delete engn;
}