class SearchController < ApplicationController
  before_action :show_title_h1

  def index
    @title = "Search"

    @search = Search.new

    if params[:q].to_s.present?
      @search.q = params[:q].to_s

      @search.what = params[:what] if params[:what].present?
      @search.order = params[:order] if params[:order].present?
      @search.page = params[:page].to_i if params[:page].present?

      @search.search_for_user!(@user) if @search.valid?
    end

    render action: "index"
  end
end
