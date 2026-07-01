/// REST broker for the Gaia brightness-variation results.
///
/// The proxy SQL here MUST stay identical to src/gaia/sql.py (build_query) —
/// the two are kept in lock-step by hand. We inline the SQL in ObjectScript
/// (rather than importing src.gaia.sql via %SYS.Python) because embedded-Python
/// import of the bind-mounted module hangs intermittently on the Community
/// Edition image. tests/test_rest_sql_parity.py asserts this string matches
/// build_query(x, limit) so the two definitions cannot silently drift.
Class Gaia.REST Extends %CSP.REST
{

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/variations" Method="GET" Call="Variations"/>
</Routes>
}

/// The flux-scatter variability proxy, filtered to pct_change >= :x and sorted
/// desc. `top` is an integer spliced in (TOP has no bind-param form); `x` is a
/// bind parameter. Both are validated as numbers by the caller, so no injection.
ClassMethod SQL(top As %Integer) As %String
{
  Quit "SELECT TOP "_top_" source_id, ra, ""dec"", mag_max, mag_min, pct_change FROM ("
    _"SELECT source_id, ra, ""dec"","
    _"phot_g_mean_mag + 2.5*LOG10(phot_g_mean_flux / GREATEST(phot_g_mean_flux - SQRT(phot_g_n_obs)*phot_g_mean_flux_error, phot_g_mean_flux*0.001)) AS mag_max,"
    _"phot_g_mean_mag - 2.5*LOG10((phot_g_mean_flux + SQRT(phot_g_n_obs)*phot_g_mean_flux_error) / phot_g_mean_flux) AS mag_min,"
    _"LEAST(SQRT(phot_g_n_obs)*phot_g_mean_flux_error / phot_g_mean_flux, 1.0) * 100 AS pct_change "
    _"FROM Gaia.Source "
    _"WHERE phot_g_mean_flux > 0 AND phot_g_n_obs > 0 AND phot_g_mean_flux_error IS NOT NULL"
    _") WHERE pct_change >= ? ORDER BY pct_change DESC"
}

ClassMethod Variations() As %Status
{
  // Coerce params to numbers so a non-numeric query string (e.g. ?x=abc) yields
  // a sane default instead of an error.
  Set x = $Get(%request.Data("x",1), 10)
  Set:'$IsValidNum(x) x = 10
  Set limit = $Get(%request.Data("limit",1), 1000)
  Set:('$IsValidNum(limit))!(limit<1) limit = 1000
  Set limit = limit \ 1
  Set stmt = ##class(%SQL.Statement).%New()
  $$$ThrowOnError(stmt.%Prepare(..SQL(limit)))
  Set rs = stmt.%Execute(x)
  Set arr = []
  While rs.%Next() {
    Set o = {}
    Set o."source_id" = rs.%GetData(1), o.ra = rs.%GetData(2), o.dec = rs.%GetData(3)
    Set o."mag_max" = rs.%GetData(4), o."mag_min" = rs.%GetData(5), o."pct_change" = rs.%GetData(6)
    Do arr.%Push(o)
  }
  Do %response.SetHeader("Content-Type","application/json")
  Write arr.%ToJSON()
  Quit $$$OK
}

}
