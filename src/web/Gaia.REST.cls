/// REST broker for the Gaia brightness-variation results, with server-side
/// pagination.
///
/// The proxy SQL here MUST stay identical to src/gaia/sql.py (build_query) —
/// the two are kept in lock-step by hand. We inline the SQL in ObjectScript
/// (rather than importing src.gaia.sql via %SYS.Python) because embedded-Python
/// import of the bind-mounted module hangs intermittently on the Community
/// Edition image. tests/test_rest_sql_parity.py asserts the inlined proxy
/// matches build_query() so the two definitions cannot silently drift.
///
/// Pagination is required: serialising the full result set (160k+ rows) into a
/// single JSON array via %ToJSON() overflows the ObjectScript string stack
/// (<STRINGSTACK> above ~5k rows). Callers page through with page/pageSize.
Class Gaia.REST Extends %CSP.REST
{

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/variations" Method="GET" Call="Variations"/>
</Routes>
}

/// The flux-scatter variability proxy as a subquery, filtered to
/// pct_change >= :x. Kept identical to src/gaia/sql.py's inner SELECT + filter.
/// Returns SQL with one bind parameter (the threshold x).
ClassMethod ProxySQL() As %String
{
  Quit "SELECT source_id, ra, ""dec"", mag_max, mag_min, pct_change FROM ("
    _"SELECT source_id, ra, ""dec"","
    _"phot_g_mean_mag + 2.5*LOG10(phot_g_mean_flux / GREATEST(phot_g_mean_flux - SQRT(phot_g_n_obs)*phot_g_mean_flux_error, phot_g_mean_flux*0.001)) AS mag_max,"
    _"phot_g_mean_mag - 2.5*LOG10((phot_g_mean_flux + SQRT(phot_g_n_obs)*phot_g_mean_flux_error) / phot_g_mean_flux) AS mag_min,"
    _"LEAST(SQRT(phot_g_n_obs)*phot_g_mean_flux_error / phot_g_mean_flux, 1.0) * 100 AS pct_change "
    _"FROM Gaia.Source "
    _"WHERE phot_g_mean_flux > 0 AND phot_g_n_obs > 0 AND phot_g_mean_flux_error IS NOT NULL"
    _") WHERE pct_change >= ?"
}

/// GET /variations?x=NN&page=P&pageSize=S
/// Returns {"x":N,"page":P,"pageSize":S,"total":T,"rows":[{...6 fields...}]}
/// sorted by pct_change desc. page is 1-based; pageSize is clamped to [1,5000].
ClassMethod Variations() As %Status
{
  // Validate params -> sane defaults (a non-numeric ?x=abc must not 500).
  Set x = $Get(%request.Data("x",1), 10)
  Set:'$IsValidNum(x) x = 10
  Set page = $Get(%request.Data("page",1), 1)
  Set:('$IsValidNum(page))!(page<1) page = 1
  Set page = page \ 1
  Set pageSize = $Get(%request.Data("pageSize",1), 100)
  Set:'$IsValidNum(pageSize) pageSize = 100
  Set pageSize = pageSize \ 1
  Set:pageSize<1 pageSize = 1
  Set:pageSize>5000 pageSize = 5000          // cap keeps %ToJSON() under the string stack
  Set proxy = ..ProxySQL()

  // total matching rows (for the UI's paging controls)
  Set cStmt = ##class(%SQL.Statement).%New()
  $$$ThrowOnError(cStmt.%Prepare("SELECT COUNT(*) FROM ("_proxy_")"))
  Set cRs = cStmt.%Execute(x)
  Do cRs.%Next()
  Set total = cRs.%GetData(1)

  // one page, via ROW_NUMBER() window over the sorted proxy
  Set lo = ((page - 1) * pageSize) + 1
  Set hi = page * pageSize
  Set pStmt = ##class(%SQL.Statement).%New()
  Set pSql = "SELECT source_id, ra, ""dec"", mag_max, mag_min, pct_change FROM ("
    _"SELECT p.*, ROW_NUMBER() OVER (ORDER BY pct_change DESC) AS rn FROM ("_proxy_") p"
    _") WHERE rn BETWEEN ? AND ?"
  $$$ThrowOnError(pStmt.%Prepare(pSql))
  Set rs = pStmt.%Execute(x, lo, hi)
  Set rows = []
  While rs.%Next() {
    Set o = {}
    Set o."source_id" = rs.%GetData(1), o.ra = rs.%GetData(2), o.dec = rs.%GetData(3)
    Set o."mag_max" = rs.%GetData(4), o."mag_min" = rs.%GetData(5), o."pct_change" = rs.%GetData(6)
    Do rows.%Push(o)
  }
  Set out = {}
  Set out.x = x, out.page = page, out.pageSize = pageSize, out.total = total
  Set out.rows = rows
  Do %response.SetHeader("Content-Type","application/json")
  Write out.%ToJSON()
  Quit $$$OK
}

}
